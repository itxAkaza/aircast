#include <windows.h>
#include <mmsystem.h>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <thread>
#include <vector>

#pragma comment(lib, "winmm.lib")

#define AIRCAST_API extern "C" __declspec(dllexport)

namespace {

    constexpr uint32_t kSampleRate = 48000;
    constexpr uint16_t kChannels = 1;
    constexpr uint16_t kBitsPerSample = 16;
    constexpr uint32_t kBytesPerSec = kSampleRate * kChannels * (kBitsPerSample / 8); // 96,000 B/s

    constexpr size_t kFrameBytes = 1920;         // 20 ms chunk
    constexpr size_t kNumBuffers = 4;            // 80 ms total hardware queue
    constexpr size_t kRingCapacity = 48000;      // 500 ms ring capacity
    constexpr size_t kPrebufferBytes = 3840;     // 40 ms prebuffer before playback
    constexpr size_t kMaxLatencyBytes = 11520;   // 120 ms ceiling (drops stale burst audio)

    std::mutex g_lifecycleMutex;
    std::mutex g_ringMutex;

    uint8_t g_ring[kRingCapacity];
    size_t g_readPos = 0;
    size_t g_writePos = 0;
    size_t g_available = 0;
    bool g_buffering = true;

    std::atomic<bool> g_running{false};
    std::atomic<bool> g_cableOpen{false};
    std::atomic<bool> g_loopbackRequested{false};
    std::atomic<bool> g_loopbackOpen{false};
    std::atomic<uint32_t> g_underruns{0};

    HANDLE g_doneEvent = nullptr;
    std::thread g_workerThread;

    HWAVEOUT g_cableOut = nullptr;
    WAVEHDR g_cableHdrs[kNumBuffers];
    std::vector<uint8_t> g_cableBufs[kNumBuffers];

    HWAVEOUT g_loopbackOut = nullptr;
    WAVEHDR g_loopbackHdrs[kNumBuffers];
    std::vector<uint8_t> g_loopbackBufs[kNumBuffers];

    WAVEFORMATEX makePcmFormat() {
        WAVEFORMATEX wfx{};
        wfx.wFormatTag = WAVE_FORMAT_PCM;
        wfx.nChannels = kChannels;
        wfx.nSamplesPerSec = kSampleRate;
        wfx.wBitsPerSample = kBitsPerSample;
        wfx.nBlockAlign = (kChannels * kBitsPerSample) / 8;
        wfx.nAvgBytesPerSec = kBytesPerSec;
        wfx.cbSize = 0;
        return wfx;
    }

    int findCableInputDeviceId() {
        const UINT numDevs = waveOutGetNumDevs();
        for (UINT i = 0; i < numDevs; ++i) {
            WAVEOUTCAPSW caps{};
            if (waveOutGetDevCapsW(i, &caps, sizeof(caps)) == MMSYSERR_NOERROR) {
                if (wcsstr(caps.szPname, L"CABLE Input") != nullptr) {
                    return static_cast<int>(i);
                }
            }
        }
        return -1;
    }

    bool hasCableOutputRecordingDevice() {
        const UINT numDevs = waveInGetNumDevs();
        for (UINT i = 0; i < numDevs; ++i) {
            WAVEINCAPSW caps{};
            if (waveInGetDevCapsW(i, &caps, sizeof(caps)) == MMSYSERR_NOERROR) {
                if (wcsstr(caps.szPname, L"CABLE Output") != nullptr) {
                    return true;
                }
            }
        }
        return false;
    }

    void clearRingLocked() {
        g_readPos = 0;
        g_writePos = 0;
        g_available = 0;
        g_buffering = true;
    }

    void pushRing(const uint8_t* data, size_t len) {
        if (data == nullptr || len == 0) return;

        if (len > kRingCapacity) {
            data += (len - kRingCapacity);
            len = kRingCapacity;
        }

        std::lock_guard<std::mutex> lock(g_ringMutex);

        if (g_available + len > kRingCapacity) {
            const size_t overflow = (g_available + len) - kRingCapacity;
            g_readPos = (g_readPos + overflow) % kRingCapacity;
            g_available -= overflow;
        }

        const size_t firstPart = (len <= (kRingCapacity - g_writePos))
                                 ? len
                                 : (kRingCapacity - g_writePos);
        std::memcpy(g_ring + g_writePos, data, firstPart);
        if (firstPart < len) {
            std::memcpy(g_ring, data + firstPart, len - firstPart);
        }
        g_writePos = (g_writePos + len) % kRingCapacity;
        g_available += len;

        // Shed stale audio if Wi-Fi bursts queued more than 120 ms
        if (g_available > kMaxLatencyBytes) {
            const size_t drop = g_available - kPrebufferBytes;
            g_readPos = (g_readPos + drop) % kRingCapacity;
            g_available -= drop;
        }

        if (g_buffering && g_available >= kPrebufferBytes) {
            g_buffering = false;
        }
    }

    bool popFrame(uint8_t* outFrame) {
        std::lock_guard<std::mutex> lock(g_ringMutex);

        if (g_buffering || g_available < kFrameBytes) {
            if (!g_buffering && g_available < kFrameBytes) {
                g_buffering = true;
                g_underruns.fetch_add(1, std::memory_order_relaxed);
            }
            std::memset(outFrame, 0, kFrameBytes);
            return false;
        }

        const size_t firstPart = (kFrameBytes <= (kRingCapacity - g_readPos))
                                 ? kFrameBytes
                                 : (kRingCapacity - g_readPos);
        std::memcpy(outFrame, g_ring + g_readPos, firstPart);
        if (firstPart < kFrameBytes) {
            std::memcpy(outFrame + firstPart, g_ring, kFrameBytes - firstPart);
        }
        g_readPos = (g_readPos + kFrameBytes) % kRingCapacity;
        g_available -= kFrameBytes;
        return true;
    }

    void closeDevice(HWAVEOUT& hOut, WAVEHDR* hdrs) {
        if (hOut == nullptr) return;
        waveOutReset(hOut);
        for (size_t i = 0; i < kNumBuffers; ++i) {
            if (hdrs[i].dwFlags & WHDR_PREPARED) {
                waveOutUnprepareHeader(hOut, &hdrs[i], sizeof(WAVEHDR));
            }
        }
        waveOutClose(hOut);
        hOut = nullptr;
    }

    bool openDevice(UINT deviceId, DWORD_PTR callback, DWORD fdwOpen,
                    HWAVEOUT& hOut, WAVEHDR* hdrs, std::vector<uint8_t>* bufs) {
        WAVEFORMATEX wfx = makePcmFormat();
        if (waveOutOpen(&hOut, deviceId, &wfx, callback, 0, fdwOpen) != MMSYSERR_NOERROR) {
            hOut = nullptr;
            return false;
        }

        for (size_t i = 0; i < kNumBuffers; ++i) {
            bufs[i].assign(kFrameBytes, 0);
            std::memset(&hdrs[i], 0, sizeof(WAVEHDR));
            hdrs[i].lpData = reinterpret_cast<LPSTR>(bufs[i].data());
            hdrs[i].dwBufferLength = static_cast<DWORD>(kFrameBytes);

            if (waveOutPrepareHeader(hOut, &hdrs[i], sizeof(WAVEHDR)) != MMSYSERR_NOERROR) {
                closeDevice(hOut, hdrs);
                return false;
            }
        }
        return true;
    }

    void writeLoopbackFrame(const uint8_t* frame) {
        if (!g_loopbackOpen.load(std::memory_order_acquire) || g_loopbackOut == nullptr) {
            return;
        }
        for (size_t i = 0; i < kNumBuffers; ++i) {
            if ((g_loopbackHdrs[i].dwFlags & WHDR_INQUEUE) == 0) {
                std::memcpy(g_loopbackBufs[i].data(), frame, kFrameBytes);
                waveOutWrite(g_loopbackOut, &g_loopbackHdrs[i], sizeof(WAVEHDR));
                return;
            }
        }
    }

    void playbackWorker() {
        uint8_t scratchFrame[kFrameBytes]{};

        // Prime all 4 VB-Cable hardware buffers with initial silence to start the 20 ms clock
        for (size_t i = 0; i < kNumBuffers; ++i) {
            std::memset(g_cableBufs[i].data(), 0, kFrameBytes);
            if (waveOutWrite(g_cableOut, &g_cableHdrs[i], sizeof(WAVEHDR)) != MMSYSERR_NOERROR) {
                g_running.store(false, std::memory_order_release);
                break;
            }
        }

        while (g_running.load(std::memory_order_acquire)) {
            // Handle dynamic Loopback toggle safely on the worker thread
            const bool wantLoopback = g_loopbackRequested.load(std::memory_order_acquire);
            const bool haveLoopback = g_loopbackOpen.load(std::memory_order_acquire);

            if (wantLoopback && !haveLoopback) {
                if (openDevice(WAVE_MAPPER, 0, CALLBACK_NULL, g_loopbackOut, g_loopbackHdrs, g_loopbackBufs)) {
                    g_loopbackOpen.store(true, std::memory_order_release);
                } else {
                    g_loopbackRequested.store(false, std::memory_order_release);
                }
            } else if (!wantLoopback && haveLoopback) {
                g_loopbackOpen.store(false, std::memory_order_release);
                closeDevice(g_loopbackOut, g_loopbackHdrs);
            }

            // Refill every completed VB-Cable buffer
            for (size_t i = 0; i < kNumBuffers; ++i) {
                if (!g_running.load(std::memory_order_acquire)) break;

                if ((g_cableHdrs[i].dwFlags & WHDR_INQUEUE) == 0) {
                    popFrame(scratchFrame);
                    std::memcpy(g_cableBufs[i].data(), scratchFrame, kFrameBytes);

                    if (waveOutWrite(g_cableOut, &g_cableHdrs[i], sizeof(WAVEHDR)) != MMSYSERR_NOERROR) {
                        g_running.store(false, std::memory_order_release);
                        break;
                    }

                    writeLoopbackFrame(scratchFrame);
                }
            }

            if (!g_running.load(std::memory_order_acquire)) break;
            WaitForSingleObject(g_doneEvent, 25);
        }

        // Always clean up both handles on exit (closeDevice safely no-ops if nullptr)
        g_loopbackOpen.store(false, std::memory_order_release);
        closeDevice(g_loopbackOut, g_loopbackHdrs);

        g_cableOpen.store(false, std::memory_order_release);
        closeDevice(g_cableOut, g_cableHdrs);
    }

    void stopInternal() {
        g_running.store(false, std::memory_order_release);
        if (g_doneEvent != nullptr) {
            SetEvent(g_doneEvent);
        }
        if (g_workerThread.joinable()) {
            g_workerThread.join();
        }
        if (g_doneEvent != nullptr) {
            CloseHandle(g_doneEvent);
            g_doneEvent = nullptr;
        }
        std::lock_guard<std::mutex> lock(g_ringMutex);
        clearRingLocked();
    }

} // namespace

/// Returns:
/// 0 = VB-Cable NOT installed
/// 1 = VB-Cable Ready (both CABLE Input and CABLE Output found)
/// 2 = Partial (CABLE Input found, CABLE Output disabled/missing)
AIRCAST_API int32_t audio_check_vbcable() {
    const int playbackId = findCableInputDeviceId();
    if (playbackId < 0) return 0;
    return hasCableOutputRecordingDevice() ? 1 : 2;
}

/// Initializes VB-Cable playback worker. Safe to call repeatedly (e.g., on Flutter hot restart).
/// Returns 1 on success, 0 if VB-Cable is missing, -1 if device failed to open.
AIRCAST_API int32_t audio_init() {
    std::lock_guard<std::mutex> lock(g_lifecycleMutex);
    stopInternal();

    const int cableId = findCableInputDeviceId();
    if (cableId < 0) {
        return 0;
    }

    g_doneEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (g_doneEvent == nullptr) {
        return -1;
    }

    if (!openDevice(static_cast<UINT>(cableId),
                    reinterpret_cast<DWORD_PTR>(g_doneEvent),
                    CALLBACK_EVENT,
                    g_cableOut,
                    g_cableHdrs,
                    g_cableBufs)) {
        CloseHandle(g_doneEvent);
        g_doneEvent = nullptr;
        return -1;
    }

    g_underruns.store(0, std::memory_order_relaxed);
    g_cableOpen.store(true, std::memory_order_release);
    g_running.store(true, std::memory_order_release);
    g_workerThread = std::thread(playbackWorker);
    return 1;
}

AIRCAST_API void audio_push(const uint8_t* data, int32_t length) {
    if (length <= 0 || data == nullptr) return;
    pushRing(data, static_cast<size_t>(length));
}

AIRCAST_API void audio_flush() {
    std::lock_guard<std::mutex> lock(g_ringMutex);
    clearRingLocked();
}

AIRCAST_API void audio_set_loopback(int32_t enabled) {
    g_loopbackRequested.store(enabled != 0, std::memory_order_release);
    if (g_doneEvent != nullptr) {
        SetEvent(g_doneEvent);
    }
}

AIRCAST_API int32_t audio_is_cable_active() {
    return g_cableOpen.load(std::memory_order_acquire) ? 1 : 0;
}

AIRCAST_API int32_t audio_is_loopback_active() {
    return g_loopbackOpen.load(std::memory_order_acquire) ? 1 : 0;
}

AIRCAST_API int32_t audio_get_buffered_ms() {
    std::lock_guard<std::mutex> lock(g_ringMutex);
    return static_cast<int32_t>((g_available * 1000) / kBytesPerSec);
}

AIRCAST_API int32_t audio_get_underruns() {
    return static_cast<int32_t>(g_underruns.load(std::memory_order_relaxed));
}

AIRCAST_API void audio_stop() {
    std::lock_guard<std::mutex> lock(g_lifecycleMutex);
    stopInternal();
}

BOOL APIENTRY DllMain(HMODULE, DWORD reason, LPVOID) {
if (reason == DLL_PROCESS_DETACH) {
g_running.store(false, std::memory_order_release);
if (g_doneEvent != nullptr) SetEvent(g_doneEvent);
}
return TRUE;
}