#define NOMINMAX
#include <windows.h>
#include <mmsystem.h>
#include <avrt.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <thread>
#include <vector>

#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "avrt.lib")

#define AIRCAST_API extern "C" __declspec(dllexport)

namespace {

    constexpr uint32_t kSampleRate = 48000;
    constexpr uint16_t kChannels = 1;
    constexpr uint16_t kBitsPerSample = 16;
    constexpr uint32_t kBytesPerSec = kSampleRate * kChannels * (kBitsPerSample / 8); // 96,000 B/s

    constexpr size_t kOutFrameSamples = 480;              // 10 ms @ 48 kHz
    constexpr size_t kOutFrameBytes = kOutFrameSamples * 2;
    constexpr size_t kNumBuffers = 4;                     // 40 ms hardware queue
    constexpr size_t kFadeSamples = 128;                  // ~2.7 ms click-free ramp

    constexpr size_t kRingSamples = 24000;                // 500 ms ring capacity
    constexpr size_t kTargetSamples = 2400;               // 50 ms steady-state target
    constexpr size_t kPrebufferSamples = 2400;            // 50 ms initial prebuffer
    constexpr size_t kHardCapSamples = 9600;              // 200 ms emergency overflow cap

    class SampleRing {
    public:
        void clear() {
            std::lock_guard<std::mutex> lock(mutex_);
            readPos_ = 0;
            writePos_ = 0;
            count_ = 0;
            prebuffering_ = true;
            consecutiveUnderruns_ = 0;
            fracPos_ = 0.0;
            smoothErr_ = 0.0;
            lastSample_ = 0;
            wasUnderrun_ = false;
        }

        void resetCounters() {
            underruns_.store(0, std::memory_order_relaxed);
            overruns_.store(0, std::memory_order_relaxed);
        }

        void pushBytes(const uint8_t* data, size_t byteLen) {
            if (data == nullptr || byteLen < 2) return;
            size_t numSamples = byteLen / 2;
            const int16_t* samples = reinterpret_cast<const int16_t*>(data);

            if (numSamples > kRingSamples) {
                samples += (numSamples - kRingSamples);
                numSamples = kRingSamples;
            }

            std::lock_guard<std::mutex> lock(mutex_);

            if (count_ + numSamples > kRingSamples) {
                const size_t overflow = (count_ + numSamples) - kRingSamples;
                readPos_ = (readPos_ + overflow) % kRingSamples;
                count_ -= overflow;
                fracPos_ = 0.0;
                overruns_.fetch_add(1, std::memory_order_relaxed);
            }

            const size_t firstPart = std::min(numSamples, kRingSamples - writePos_);
            std::memcpy(buf_ + writePos_, samples, firstPart * sizeof(int16_t));
            if (firstPart < numSamples) {
                std::memcpy(buf_, samples + firstPart, (numSamples - firstPart) * sizeof(int16_t));
            }
            writePos_ = (writePos_ + numSamples) % kRingSamples;
            count_ += numSamples;

            // Emergency cap only if Wi-Fi stalled > 200 ms and dumped a huge backlog
            if (count_ > kHardCapSamples) {
                const size_t drop = count_ - kTargetSamples;
                readPos_ = (readPos_ + drop) % kRingSamples;
                count_ -= drop;
                fracPos_ = 0.0;
                overruns_.fetch_add(1, std::memory_order_relaxed);
            }

            if (prebuffering_ && count_ >= kPrebufferSamples) {
                prebuffering_ = false;
                consecutiveUnderruns_ = 0;
            }
        }

        bool renderFrame(int16_t* out, size_t outSamples) {
            std::lock_guard<std::mutex> lock(mutex_);

            if (prebuffering_) {
                writeFadeOutSilence(out, outSamples);
                return false;
            }

            // Smooth PI-style drift control: nudges speed by up to ±0.6% (~10 cents, inaudible)
            const double err = (static_cast<double>(count_) - static_cast<double>(kTargetSamples)) /
                               static_cast<double>(kTargetSamples);
            smoothErr_ = 0.98 * smoothErr_ + 0.02 * err;
            const double delta = std::clamp(smoothErr_ * 0.006, -0.006, 0.006);
            const double ratio = 1.0 + delta;

            const size_t needed = static_cast<size_t>(std::ceil(fracPos_ + outSamples * ratio)) + 2;
            if (count_ < needed) {
                underruns_.fetch_add(1, std::memory_order_relaxed);
                consecutiveUnderruns_++;
                wasUnderrun_ = true;

                // Only re-prebuffer after 100 ms continuous dropout, not on a 10 ms hiccup
                if (consecutiveUnderruns_ >= 10) {
                    prebuffering_ = true;
                }
                writeFadeOutSilence(out, outSamples);
                return false;
            }

            consecutiveUnderruns_ = 0;
            double pos = fracPos_;

            for (size_t i = 0; i < outSamples; ++i) {
                const size_t idx0 = static_cast<size_t>(pos);
                const double frac = pos - static_cast<double>(idx0);
                const int16_t s0 = buf_[(readPos_ + idx0) % kRingSamples];
                const int16_t s1 = buf_[(readPos_ + idx0 + 1) % kRingSamples];
                const double interp = static_cast<double>(s0) +
                                      (static_cast<double>(s1) - static_cast<double>(s0)) * frac;
                out[i] = static_cast<int16_t>(std::clamp(std::lround(interp), -32768L, 32767L));
                pos += ratio;
            }

            const size_t consumed = static_cast<size_t>(pos);
            readPos_ = (readPos_ + consumed) % kRingSamples;
            count_ -= consumed;
            fracPos_ = pos - static_cast<double>(consumed);

            if (wasUnderrun_) {
                const size_t ramp = std::min(kFadeSamples, outSamples);
                for (size_t i = 0; i < ramp; ++i) {
                    const double gain = static_cast<double>(i) / static_cast<double>(ramp);
                    out[i] = static_cast<int16_t>(std::lround(out[i] * gain));
                }
                wasUnderrun_ = false;
            }

            lastSample_ = out[outSamples - 1];
            return true;
        }

        int32_t bufferedMs() const {
            std::lock_guard<std::mutex> lock(mutex_);
            return static_cast<int32_t>((count_ * 1000) / kSampleRate);
        }

        uint32_t underruns() const { return underruns_.load(std::memory_order_relaxed); }
        uint32_t overruns() const { return overruns_.load(std::memory_order_relaxed); }

    private:
        void writeFadeOutSilence(int16_t* out, size_t outSamples) {
            std::memset(out, 0, outSamples * sizeof(int16_t));
            if (lastSample_ != 0) {
                const size_t ramp = std::min(kFadeSamples, outSamples);
                for (size_t i = 0; i < ramp; ++i) {
                    const double gain = 1.0 - (static_cast<double>(i + 1) / static_cast<double>(ramp));
                    out[i] = static_cast<int16_t>(std::lround(lastSample_ * gain));
                }
                lastSample_ = 0;
            }
        }

        mutable std::mutex mutex_;
        int16_t buf_[kRingSamples]{};
        size_t readPos_ = 0;
        size_t writePos_ = 0;
        size_t count_ = 0;
        bool prebuffering_ = true;
        int consecutiveUnderruns_ = 0;
        double fracPos_ = 0.0;
        double smoothErr_ = 0.0;
        int16_t lastSample_ = 0;
        bool wasUnderrun_ = false;
        std::atomic<uint32_t> underruns_{0};
        std::atomic<uint32_t> overruns_{0};
    };

    struct OutputChannel {
        SampleRing ring;
        std::mutex lifecycleMutex;
        std::atomic<bool> running{false};
        std::atomic<bool> open{false};
        HANDLE doneEvent = nullptr;
        std::thread worker;
        HWAVEOUT hOut = nullptr;
        WAVEHDR hdrs[kNumBuffers]{};
        std::vector<int16_t> bufs[kNumBuffers];
    };

    OutputChannel g_cable;
    OutputChannel g_loopback;
    std::mutex g_timerMutex;
    bool g_timerPeriodActive = false;

    void setTimerPeriod(bool enable) {
        std::lock_guard<std::mutex> lock(g_timerMutex);
        if (enable && !g_timerPeriodActive) {
            timeBeginPeriod(1);
            g_timerPeriodActive = true;
        } else if (!enable && g_timerPeriodActive) {
            timeEndPeriod(1);
            g_timerPeriodActive = false;
        }
    }

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

    void closeChannelDevice(OutputChannel& ch) {
        if (ch.hOut == nullptr) return;
        waveOutReset(ch.hOut);
        for (size_t i = 0; i < kNumBuffers; ++i) {
            if (ch.hdrs[i].dwFlags & WHDR_PREPARED) {
                waveOutUnprepareHeader(ch.hOut, &ch.hdrs[i], sizeof(WAVEHDR));
            }
        }
        waveOutClose(ch.hOut);
        ch.hOut = nullptr;
    }

    bool openChannelDevice(OutputChannel& ch, UINT deviceId) {
        WAVEFORMATEX wfx = makePcmFormat();
        if (waveOutOpen(&ch.hOut,
                        deviceId,
                        &wfx,
                        reinterpret_cast<DWORD_PTR>(ch.doneEvent),
                        0,
                        CALLBACK_EVENT) != MMSYSERR_NOERROR) {
            ch.hOut = nullptr;
            return false;
        }

        for (size_t i = 0; i < kNumBuffers; ++i) {
            ch.bufs[i].assign(kOutFrameSamples, 0);
            std::memset(&ch.hdrs[i], 0, sizeof(WAVEHDR));
            ch.hdrs[i].lpData = reinterpret_cast<LPSTR>(ch.bufs[i].data());
            ch.hdrs[i].dwBufferLength = static_cast<DWORD>(kOutFrameBytes);

            if (waveOutPrepareHeader(ch.hOut, &ch.hdrs[i], sizeof(WAVEHDR)) != MMSYSERR_NOERROR) {
                closeChannelDevice(ch);
                return false;
            }
        }
        return true;
    }

    void channelWorkerLoop(OutputChannel* ch) {
        DWORD taskIndex = 0;
        HANDLE mmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);
        if (mmcss == nullptr) {
            SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
        }

        // Prime all 4 buffers with silence to start the 10 ms completion clock
        for (size_t i = 0; i < kNumBuffers; ++i) {
            std::fill(ch->bufs[i].begin(), ch->bufs[i].end(), 0);
            if (waveOutWrite(ch->hOut, &ch->hdrs[i], sizeof(WAVEHDR)) != MMSYSERR_NOERROR) {
                ch->running.store(false, std::memory_order_release);
                break;
            }
        }

        while (ch->running.load(std::memory_order_acquire)) {
            for (size_t i = 0; i < kNumBuffers; ++i) {
                if (!ch->running.load(std::memory_order_acquire)) break;

                if ((ch->hdrs[i].dwFlags & WHDR_INQUEUE) == 0) {
                    ch->ring.renderFrame(ch->bufs[i].data(), kOutFrameSamples);
                    if (waveOutWrite(ch->hOut, &ch->hdrs[i], sizeof(WAVEHDR)) != MMSYSERR_NOERROR) {
                        ch->running.store(false, std::memory_order_release);
                        break;
                    }
                }
            }

            if (!ch->running.load(std::memory_order_acquire)) break;
            WaitForSingleObject(ch->doneEvent, 15);
        }

        ch->open.store(false, std::memory_order_release);
        closeChannelDevice(*ch);

        if (mmcss != nullptr) {
            AvRevertMmThreadCharacteristics(mmcss);
        }
    }

    void stopChannelLocked(OutputChannel& ch) {
        ch.running.store(false, std::memory_order_release);
        if (ch.doneEvent != nullptr) {
            SetEvent(ch.doneEvent);
        }
        if (ch.worker.joinable()) {
            ch.worker.join();
        }
        if (ch.doneEvent != nullptr) {
            CloseHandle(ch.doneEvent);
            ch.doneEvent = nullptr;
        }
        ch.ring.clear();
    }

    bool startChannelLocked(OutputChannel& ch, UINT deviceId) {
        stopChannelLocked(ch);

        ch.doneEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (ch.doneEvent == nullptr) return false;

        if (!openChannelDevice(ch, deviceId)) {
            CloseHandle(ch.doneEvent);
            ch.doneEvent = nullptr;
            return false;
        }

        ch.ring.clear();
        ch.ring.resetCounters();
        ch.open.store(true, std::memory_order_release);
        ch.running.store(true, std::memory_order_release);
        ch.worker = std::thread(channelWorkerLoop, &ch);
        return true;
    }

} // namespace

AIRCAST_API int32_t audio_check_vbcable() {
    const int playbackId = findCableInputDeviceId();
    if (playbackId < 0) return 0;
    return hasCableOutputRecordingDevice() ? 1 : 2;
}

AIRCAST_API int32_t audio_init() {
    std::lock_guard<std::mutex> lock(g_cable.lifecycleMutex);
    const int cableId = findCableInputDeviceId();
    if (cableId < 0) {
        stopChannelLocked(g_cable);
        return 0;
    }

    setTimerPeriod(true);
    if (!startChannelLocked(g_cable, static_cast<UINT>(cableId))) {
        return -1;
    }
    return 1;
}

AIRCAST_API void audio_push(const uint8_t* data, int32_t length) {
    if (length <= 0 || data == nullptr) return;
    const size_t byteLen = static_cast<size_t>(length);
    if (g_cable.open.load(std::memory_order_acquire)) {
        g_cable.ring.pushBytes(data, byteLen);
    }
    if (g_loopback.open.load(std::memory_order_acquire)) {
        g_loopback.ring.pushBytes(data, byteLen);
    }
}

AIRCAST_API void audio_flush() {
    g_cable.ring.clear();
    g_loopback.ring.clear();
}

AIRCAST_API void audio_set_loopback(int32_t enabled) {
    std::lock_guard<std::mutex> lock(g_loopback.lifecycleMutex);
    if (enabled != 0) {
        if (!g_loopback.open.load(std::memory_order_acquire)) {
            setTimerPeriod(true);
            startChannelLocked(g_loopback, WAVE_MAPPER);
        }
    } else {
        stopChannelLocked(g_loopback);
    }
}

AIRCAST_API int32_t audio_is_cable_active() {
    return g_cable.open.load(std::memory_order_acquire) ? 1 : 0;
}

AIRCAST_API int32_t audio_is_loopback_active() {
    return g_loopback.open.load(std::memory_order_acquire) ? 1 : 0;
}

AIRCAST_API int32_t audio_get_buffered_ms() {
    return g_cable.ring.bufferedMs();
}

AIRCAST_API int32_t audio_get_underruns() {
    return static_cast<int32_t>(g_cable.ring.underruns());
}

AIRCAST_API int32_t audio_get_overruns() {
    return static_cast<int32_t>(g_cable.ring.overruns());
}

AIRCAST_API void audio_stop() {
    {
        std::lock_guard<std::mutex> lock(g_loopback.lifecycleMutex);
        stopChannelLocked(g_loopback);
    }
    {
        std::lock_guard<std::mutex> lock(g_cable.lifecycleMutex);
        stopChannelLocked(g_cable);
    }
    setTimerPeriod(false);
}

BOOL APIENTRY DllMain(HMODULE, DWORD reason, LPVOID) {
if (reason == DLL_PROCESS_DETACH) {
g_loopback.running.store(false, std::memory_order_release);
g_cable.running.store(false, std::memory_order_release);
if (g_loopback.doneEvent != nullptr) SetEvent(g_loopback.doneEvent);
if (g_cable.doneEvent != nullptr) SetEvent(g_cable.doneEvent);
}
return TRUE;
}