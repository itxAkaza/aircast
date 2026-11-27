#define NOMINMAX
#include <cmath>
#include <chrono>
#include <windows.h>
#include <shellapi.h>
#include <mmsystem.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "aircast_shm.h"

#define AIRCAST_API extern "C" __declspec(dllexport)

namespace {

    using Microsoft::WRL::ComPtr;

    constexpr uint32_t kPreviewWidth = 640;
    constexpr uint32_t kPreviewHeight = 360;
    constexpr uint32_t kPreviewBytes = kPreviewWidth * kPreviewHeight * 4; // RGBA32

    std::mutex g_videoMutex;
    aircast::ShmWriter g_shmWriter;

// Test pattern worker
    std::atomic<bool> g_testRunning{false};
    std::thread g_testThread;

// WIC JPEG decode worker (single latest-frame slot)
    struct PendingJpeg {
        std::vector<uint8_t> bytes;
        int32_t rotation = 0;
        bool mirror = false;
        uint64_t timestampMs = 0;
        bool hasData = false;
    };

    std::mutex g_queueMutex;
    std::condition_variable g_queueCv;
    PendingJpeg g_pending;
    std::atomic<bool> g_decoderRunning{false};
    std::thread g_decoderThread;

// Transform & privacy controls
    std::atomic<int32_t> g_fitMode{0};         // 0 = Fill (crop), 1 = Fit (letterbox)
    std::atomic<int32_t> g_extraRotation{0};   // 0, 90, 180, 270
    std::atomic<bool> g_extraMirror{false};
    std::atomic<bool> g_privacyCut{false};

// Telemetry
    std::atomic<uint32_t> g_framesPublished{0};
    std::atomic<uint32_t> g_framesDecoded{0};
    std::atomic<uint32_t> g_framesDropped{0};
    std::atomic<uint32_t> g_lastSourceW{0};
    std::atomic<uint32_t> g_lastSourceH{0};

// Downscaled 640x360 RGBA32 preview buffer for Flutter UI & PiP
    std::mutex g_previewMutex;
    std::vector<uint8_t> g_previewRgba(kPreviewBytes, 0);
    std::atomic<uint64_t> g_previewSeq{0};

    std::wstring getSiblingVcamDllPath() {
        HMODULE selfMod = nullptr;
        GetModuleHandleExW(
                GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                reinterpret_cast<LPCWSTR>(&getSiblingVcamDllPath),
                &selfMod);

        wchar_t path[MAX_PATH]{};
        if (GetModuleFileNameW(selfMod, path, MAX_PATH) == 0) return L"";

        std::wstring full(path);
        const size_t slash = full.find_last_of(L"\\/");
        if (slash == std::wstring::npos) return L"";
        return full.substr(0, slash + 1) + L"aircast_vcam.dll";
    }

    void updatePreviewFromBgra1280x720(const uint8_t* srcBgra) {
        std::lock_guard<std::mutex> lock(g_previewMutex);
        uint8_t* dst = g_previewRgba.data();

        for (uint32_t py = 0; py < kPreviewHeight; ++py) {
            const uint8_t* sRow = srcBgra + (py * 2) * aircast::kVcamStride;
            uint8_t* dRow = dst + py * (kPreviewWidth * 4);
            for (uint32_t px = 0; px < kPreviewWidth; ++px) {
                const uint8_t* s = sRow + (px * 2) * 4;
                dRow[px * 4 + 0] = s[2]; // R
                dRow[px * 4 + 1] = s[1]; // G
                dRow[px * 4 + 2] = s[0]; // B
                dRow[px * 4 + 3] = 255;  // A
            }
        }
        g_previewSeq.fetch_add(1, std::memory_order_release);
    }

    void clearPreviewBuffer() {
        std::lock_guard<std::mutex> lock(g_previewMutex);
        std::fill(g_previewRgba.begin(), g_previewRgba.end(), 0);
        g_previewSeq.fetch_add(1, std::memory_order_release);
    }

    void drawMovingSmpteBars(uint8_t* bgra, uint32_t frameIdx) {
        constexpr uint32_t W = aircast::kVcamWidth;
        constexpr uint32_t H = aircast::kVcamHeight;

        static constexpr uint8_t kBars[8][3] = {
                {235, 235, 235}, { 16, 235, 235}, {235, 235,  16}, { 16, 235,  16},
                {235,  16, 235}, { 16,  16, 235}, {235,  16,  16}, { 24,  24,  28},
        };

        const uint32_t barW = W / 8;
        const uint32_t ballX = (frameIdx * 12) % (W - 80);
        const uint32_t ballY = 480 + static_cast<uint32_t>((frameIdx * 4) % 160);

        for (uint32_t y = 0; y < H; ++y) {
            uint8_t* row = bgra + y * aircast::kVcamStride;
            const bool inLowerStrip = (y >= H - 140);

            for (uint32_t x = 0; x < W; ++x) {
                uint8_t b, g, r;
                if (inLowerStrip) {
                    const uint32_t wave = ((x + frameIdx * 8) / 32) & 1;
                    b = wave ? 40 : 18;
                    g = wave ? 120 : 18;
                    r = wave ? 255 : 22;
                } else {
                    const uint32_t idx = (x / barW) & 7;
                    b = kBars[idx][0];
                    g = kBars[idx][1];
                    r = kBars[idx][2];
                }

                if (x >= ballX && x < ballX + 64 && y >= ballY && y < ballY + 64) {
                    r = 255; g = 115; b = 29;
                }

                row[x * 4 + 0] = b;
                row[x * 4 + 1] = g;
                row[x * 4 + 2] = r;
                row[x * 4 + 3] = 255;
            }
        }
    }

    void transformBgraTo1280x720(const uint8_t* src, uint32_t srcW, uint32_t srcH,
                                 uint8_t* dst, int32_t totalRot, bool mirror, int32_t fitMode) {
        constexpr uint32_t dstW = aircast::kVcamWidth;
        constexpr uint32_t dstH = aircast::kVcamHeight;
        const int32_t rot = ((totalRot % 360) + 360) % 360;
        const bool swapped = (rot == 90 || rot == 270);
        const uint32_t rotW = swapped ? srcH : srcW;
        const uint32_t rotH = swapped ? srcW : srcH;

        const double scaleX = static_cast<double>(dstW) / static_cast<double>(rotW);
        const double scaleY = static_cast<double>(dstH) / static_cast<double>(rotH);
        const double scale = (fitMode == 1) ? std::min(scaleX, scaleY) : std::max(scaleX, scaleY);

        const double drawnW = rotW * scale;
        const double drawnH = rotH * scale;
        const double offsetX = (dstW - drawnW) * 0.5;
        const double offsetY = (dstH - drawnH) * 0.5;
        const double invScale = 1.0 / scale;

        // Fast dark background clear when letterboxing (Fit mode)
        if (fitMode == 1) {
            std::memset(dst, 16, aircast::kVcamFrameBytes);
        }

        const int32_t xStart = std::max<int32_t>(0, static_cast<int32_t>(std::ceil(offsetX)));
        const int32_t xEnd   = std::min<int32_t>(dstW, static_cast<int32_t>(std::floor(offsetX + drawnW)));
        const int32_t yStart = std::max<int32_t>(0, static_cast<int32_t>(std::ceil(offsetY)));
        const int32_t yEnd   = std::min<int32_t>(dstH, static_cast<int32_t>(std::floor(offsetY + drawnH)));

        for (int32_t dy = yStart; dy < yEnd; ++dy) {
            const uint32_t ry = std::min<uint32_t>(
                    rotH - 1,
                    static_cast<uint32_t>(std::max(0.0, (dy - offsetY) * invScale)));
            uint32_t* dstRow = reinterpret_cast<uint32_t*>(dst + dy * aircast::kVcamStride);

            for (int32_t dx = xStart; dx < xEnd; ++dx) {
                uint32_t rx = std::min<uint32_t>(
                        rotW - 1,
                        static_cast<uint32_t>(std::max(0.0, (dx - offsetX) * invScale)));
                if (mirror) {
                    rx = rotW - 1 - rx;
                }

                uint32_t sx = 0;
                uint32_t sy = 0;
                switch (rot) {
                    case 90:
                        sx = ry;
                        sy = srcH - 1 - rx;
                        break;
                    case 180:
                        sx = srcW - 1 - rx;
                        sy = srcH - 1 - ry;
                        break;
                    case 270:
                        sx = srcW - 1 - ry;
                        sy = rx;
                        break;
                    default:
                        sx = rx;
                        sy = ry;
                        break;
                }

                const uint32_t* srcRow = reinterpret_cast<const uint32_t*>(src + sy * (srcW * 4));
                dstRow[dx] = srcRow[sx];
            }
        }
    }

    void decoderWorkerLoop() {
        const HRESULT coHr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        ComPtr<IWICImagingFactory> factory;
        if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&factory)))) {
            if (SUCCEEDED(coHr)) CoUninitialize();
            return;
        }

        std::vector<uint8_t> decodeBuf;
        PendingJpeg job;

        while (g_decoderRunning.load(std::memory_order_acquire)) {
            {
                std::unique_lock<std::mutex> lock(g_queueMutex);
                g_queueCv.wait_for(lock, std::chrono::milliseconds(100), [] {
                    return g_pending.hasData || !g_decoderRunning.load(std::memory_order_acquire);
                });
                if (!g_decoderRunning.load(std::memory_order_acquire)) break;
                if (!g_pending.hasData) continue;

                job.bytes.swap(g_pending.bytes);
                job.rotation = g_pending.rotation;
                job.mirror = g_pending.mirror;
                job.timestampMs = g_pending.timestampMs;
                g_pending.hasData = false;
            }

            if (g_privacyCut.load(std::memory_order_acquire)) {
                g_shmWriter.markIdle();
                continue;
            }

            if (job.bytes.empty()) continue;

            ComPtr<IWICStream> stream;
            if (FAILED(factory->CreateStream(&stream))) continue;
            if (FAILED(stream->InitializeFromMemory(job.bytes.data(), static_cast<DWORD>(job.bytes.size())))) {
                continue;
            }

            ComPtr<IWICBitmapDecoder> decoder;
            if (FAILED(factory->CreateDecoderFromStream(stream.Get(), nullptr,
                                                        WICDecodeMetadataCacheOnDemand, &decoder))) {
                continue;
            }

            ComPtr<IWICBitmapFrameDecode> frame;
            if (FAILED(decoder->GetFrame(0, &frame))) continue;

            UINT srcW = 0, srcH = 0;
            if (FAILED(frame->GetSize(&srcW, &srcH)) || srcW == 0 || srcH == 0) continue;

            ComPtr<IWICFormatConverter> converter;
            if (FAILED(factory->CreateFormatConverter(&converter))) continue;
            if (FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                                             WICBitmapDitherTypeNone, nullptr, 0.0,
                                             WICBitmapPaletteTypeCustom))) {
                continue;
            }

            const UINT srcStride = srcW * 4;
            const size_t neededBytes = static_cast<size_t>(srcStride) * srcH;
            if (decodeBuf.size() < neededBytes) {
                decodeBuf.resize(neededBytes);
            }
            if (FAILED(converter->CopyPixels(nullptr, srcStride, static_cast<UINT>(neededBytes),
                                             decodeBuf.data()))) {
                continue;
            }

            g_lastSourceW.store(srcW, std::memory_order_relaxed);
            g_lastSourceH.store(srcH, std::memory_order_relaxed);

            uint8_t* dstSlot = g_shmWriter.acquireWriteSlot();
            if (dstSlot != nullptr) {
                const int32_t totalRot = job.rotation + g_extraRotation.load(std::memory_order_relaxed);
                const bool totalMirror = job.mirror ^ g_extraMirror.load(std::memory_order_relaxed);
                const int32_t fitMode = g_fitMode.load(std::memory_order_relaxed);

                transformBgraTo1280x720(decodeBuf.data(), srcW, srcH, dstSlot, totalRot, totalMirror, fitMode);
                g_shmWriter.commitWriteSlot(job.timestampMs);
                updatePreviewFromBgra1280x720(dstSlot);

                g_framesDecoded.fetch_add(1, std::memory_order_relaxed);
                g_framesPublished.fetch_add(1, std::memory_order_relaxed);
            }
        }

        factory.Reset();
        if (SUCCEEDED(coHr)) CoUninitialize();
    }

    void testPatternLoop() {
        timeBeginPeriod(1);
        uint32_t idx = 0;
        LARGE_INTEGER qpf{}, qpcStart{};
        QueryPerformanceFrequency(&qpf);
        QueryPerformanceCounter(&qpcStart);

        while (g_testRunning.load(std::memory_order_acquire)) {
            if (g_privacyCut.load(std::memory_order_acquire)) {
                g_shmWriter.markIdle();
            } else {
                uint8_t* slot = g_shmWriter.acquireWriteSlot();
                if (slot != nullptr) {
                    drawMovingSmpteBars(slot, idx);
                    g_shmWriter.commitWriteSlot(GetTickCount64());
                    updatePreviewFromBgra1280x720(slot);
                    g_framesPublished.fetch_add(1, std::memory_order_relaxed);
                }
            }
            ++idx;

            const double targetSec = static_cast<double>(idx) / 30.0;
            LARGE_INTEGER qpcNow{};
            QueryPerformanceCounter(&qpcNow);
            const double elapsedSec = static_cast<double>(qpcNow.QuadPart - qpcStart.QuadPart) /
                                      static_cast<double>(qpf.QuadPart);
            const double remainMs = (targetSec - elapsedSec) * 1000.0;
            if (remainMs > 1.0) {
                Sleep(static_cast<DWORD>(remainMs));
            }
        }

        g_shmWriter.markIdle();
        timeEndPeriod(1);
    }

    void stopTestInternal() {
        g_testRunning.store(false, std::memory_order_release);
        if (g_testThread.joinable()) {
            g_testThread.join();
        }
    }

    void ensureDecoderStartedLocked() {
        if (g_decoderRunning.load(std::memory_order_acquire)) return;
        g_decoderRunning.store(true, std::memory_order_release);
        g_decoderThread = std::thread(decoderWorkerLoop);
    }

    void stopDecoderInternal() {
        g_decoderRunning.store(false, std::memory_order_release);
        g_queueCv.notify_all();
        if (g_decoderThread.joinable()) {
            g_decoderThread.join();
        }
        std::lock_guard<std::mutex> qlock(g_queueMutex);
        g_pending.bytes.clear();
        g_pending.hasData = false;
    }

} // namespace

// ---------------------------------------------------------------------------
// Phase 3A Exports (Registration, SHM, Test Pattern)
// ---------------------------------------------------------------------------
AIRCAST_API int32_t video_is_vcam_registered() {
    const std::wstring keyPath = std::wstring(L"CLSID\\") + aircast::kVcamClsidStr + L"\\InprocServer32";
    HKEY hKey = nullptr;
    if (RegOpenKeyExW(HKEY_CLASSES_ROOT, keyPath.c_str(), 0, KEY_READ, &hKey) != ERROR_SUCCESS) {
        return 0;
    }
    wchar_t registeredPath[MAX_PATH]{};
    DWORD cb = sizeof(registeredPath);
    const LONG rc = RegQueryValueExW(hKey, nullptr, nullptr, nullptr,
                                     reinterpret_cast<LPBYTE>(registeredPath), &cb);
    RegCloseKey(hKey);
    if (rc != ERROR_SUCCESS || registeredPath[0] == L'\0') return 0;
    return (GetFileAttributesW(registeredPath) != INVALID_FILE_ATTRIBUTES) ? 1 : 0;
}

AIRCAST_API int32_t video_set_vcam_registration(int32_t registerFlag) {
    const std::wstring vcamPath = getSiblingVcamDllPath();
    if (vcamPath.empty() || GetFileAttributesW(vcamPath.c_str()) == INVALID_FILE_ATTRIBUTES) {
        return -1;
    }

    const std::wstring params = (registerFlag != 0)
                                ? (L"/s \"" + vcamPath + L"\"")
                                : (L"/s /u \"" + vcamPath + L"\"");

    SHELLEXECUTEINFOW sei{};
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"runas";
    sei.lpFile = L"regsvr32.exe";
    sei.lpParameters = params.c_str();
    sei.nShow = SW_HIDE;

    if (!ShellExecuteExW(&sei)) {
        return (GetLastError() == ERROR_CANCELLED) ? 0 : -2;
    }

    DWORD exitCode = 1;
    if (sei.hProcess != nullptr) {
        WaitForSingleObject(sei.hProcess, 15000);
        GetExitCodeProcess(sei.hProcess, &exitCode);
        CloseHandle(sei.hProcess);
    }
    return (exitCode == 0) ? 1 : -2;
}

AIRCAST_API int32_t video_shm_init() {
    std::lock_guard<std::mutex> lock(g_videoMutex);
    if (!g_shmWriter.open()) return 0;
    ensureDecoderStartedLocked();
    return 1;
}

AIRCAST_API int32_t video_start_test_pattern() {
    std::lock_guard<std::mutex> lock(g_videoMutex);
    stopTestInternal();
    if (!g_shmWriter.open()) return 0;
    g_framesPublished.store(0, std::memory_order_relaxed);
    g_testRunning.store(true, std::memory_order_release);
    g_testThread = std::thread(testPatternLoop);
    return 1;
}

AIRCAST_API void video_stop_test_pattern() {
    std::lock_guard<std::mutex> lock(g_videoMutex);
    stopTestInternal();
}

AIRCAST_API int32_t video_is_test_running() {
    return g_testRunning.load(std::memory_order_acquire) ? 1 : 0;
}

AIRCAST_API int32_t video_get_frames_published() {
    return static_cast<int32_t>(g_framesPublished.load(std::memory_order_relaxed));
}

// ---------------------------------------------------------------------------
// Phase 3B Exports (Non-blocking JPEG Decode Queue, Transforms, Preview)
// ---------------------------------------------------------------------------
AIRCAST_API void video_push_jpeg(const uint8_t* data, int32_t length,
                                 int32_t rotation, int32_t mirror, int64_t timestampMs) {
    if (data == nullptr || length <= 0 || length > 4 * 1024 * 1024) return;
    if (!g_decoderRunning.load(std::memory_order_acquire)) return;

    {
        std::lock_guard<std::mutex> lock(g_queueMutex);
        if (g_pending.hasData) {
            g_framesDropped.fetch_add(1, std::memory_order_relaxed);
        }
        g_pending.bytes.assign(data, data + length);
        g_pending.rotation = rotation;
        g_pending.mirror = (mirror != 0);
        g_pending.timestampMs = static_cast<uint64_t>(timestampMs);
        g_pending.hasData = true;
    }
    g_queueCv.notify_one();
}

AIRCAST_API void video_set_transforms(int32_t fitMode, int32_t extraRotation, int32_t extraMirror) {
    g_fitMode.store(fitMode != 0 ? 1 : 0, std::memory_order_relaxed);
    g_extraRotation.store(extraRotation, std::memory_order_relaxed);
    g_extraMirror.store(extraMirror != 0, std::memory_order_relaxed);
}

AIRCAST_API void video_set_privacy_cut(int32_t enabled) {
    const bool cut = (enabled != 0);
    g_privacyCut.store(cut, std::memory_order_release);
    if (cut) {
        g_shmWriter.markIdle();
        clearPreviewBuffer();
    }
}

AIRCAST_API void video_mark_idle() {
    g_shmWriter.markIdle();
}

AIRCAST_API int32_t video_get_frames_decoded() {
    return static_cast<int32_t>(g_framesDecoded.load(std::memory_order_relaxed));
}

AIRCAST_API int32_t video_get_frames_dropped() {
    return static_cast<int32_t>(g_framesDropped.load(std::memory_order_relaxed));
}

AIRCAST_API int32_t video_get_source_width() {
    return static_cast<int32_t>(g_lastSourceW.load(std::memory_order_relaxed));
}

AIRCAST_API int32_t video_get_source_height() {
    return static_cast<int32_t>(g_lastSourceH.load(std::memory_order_relaxed));
}

AIRCAST_API int64_t video_get_preview_seq() {
    return static_cast<int64_t>(g_previewSeq.load(std::memory_order_acquire));
}

/// Copies the latest 640x360 RGBA32 preview frame into dst. Returns 1 if copied.
AIRCAST_API int32_t video_copy_preview_rgba(uint8_t* dst, int32_t maxBytes) {
    if (dst == nullptr || maxBytes < static_cast<int32_t>(kPreviewBytes)) return 0;
    std::lock_guard<std::mutex> lock(g_previewMutex);
    std::memcpy(dst, g_previewRgba.data(), kPreviewBytes);
    return 1;
}

AIRCAST_API void video_shutdown() {
    std::lock_guard<std::mutex> lock(g_videoMutex);
    stopTestInternal();
    stopDecoderInternal();
    g_shmWriter.close();
}

BOOL APIENTRY DllMain(HMODULE, DWORD reason, LPVOID) {
if (reason == DLL_PROCESS_DETACH) {
g_testRunning.store(false, std::memory_order_release);
g_decoderRunning.store(false, std::memory_order_release);
}
return TRUE;
}