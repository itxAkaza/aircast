#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <mmsystem.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

#include "aircast_shm.h"

#define AIRCAST_API extern "C" __declspec(dllexport)

namespace {

    std::mutex g_videoMutex;
    aircast::ShmWriter g_shmWriter;
    std::atomic<bool> g_testRunning{false};
    std::thread g_testThread;
    std::atomic<uint32_t> g_framesPublished{0};

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

    void drawMovingSmpteBars(uint8_t* bgra, uint32_t frameIdx) {
        constexpr uint32_t W = aircast::kVcamWidth;
        constexpr uint32_t H = aircast::kVcamHeight;

        // 8-color SMPTE-style bar palette (B, G, R)
        static constexpr uint8_t kBars[8][3] = {
                {235, 235, 235}, // White
                { 16, 235, 235}, // Yellow
                {235, 235,  16}, // Cyan
                { 16, 235,  16}, // Green
                {235,  16, 235}, // Magenta
                { 16,  16, 235}, // Red
                {235,  16,  16}, // Blue
                { 24,  24,  28}, // Dark charcoal
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
                    r = wave ? 255 : 22; // Animated AirCast orange stripes
                } else {
                    const uint32_t idx = (x / barW) & 7;
                    b = kBars[idx][0];
                    g = kBars[idx][1];
                    r = kBars[idx][2];
                }

                // Moving bright indicator square to prove live 30 FPS motion
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

    void testPatternLoop() {
        timeBeginPeriod(1);
        uint32_t idx = 0;
        LARGE_INTEGER qpf{}, qpcStart{};
        QueryPerformanceFrequency(&qpf);
        QueryPerformanceCounter(&qpcStart);

        while (g_testRunning.load(std::memory_order_acquire)) {
            uint8_t* slot = g_shmWriter.acquireWriteSlot();
            if (slot != nullptr) {
                drawMovingSmpteBars(slot, idx);
                g_shmWriter.commitWriteSlot(GetTickCount64());
                g_framesPublished.fetch_add(1, std::memory_order_relaxed);
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

} // namespace

/// Returns 1 if AirCast Camera COM filter is registered in HKCR\CLSID, else 0.
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

    // Verify registered DLL file still exists on disk
    return (GetFileAttributesW(registeredPath) != INVALID_FILE_ATTRIBUTES) ? 1 : 0;
}

/// Triggers a single UAC prompt to register (1) or unregister (0) aircast_vcam.dll.
/// Returns: 1 = success, 0 = user cancelled UAC, -1 = DLL missing, -2 = regsvr32 failed.
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
        const DWORD err = GetLastError();
        return (err == ERROR_CANCELLED) ? 0 : -2;
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
    return g_shmWriter.open() ? 1 : 0;
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

AIRCAST_API void video_shutdown() {
    std::lock_guard<std::mutex> lock(g_videoMutex);
    stopTestInternal();
    g_shmWriter.close();
}

BOOL APIENTRY DllMain(HMODULE, DWORD reason, LPVOID) {
if (reason == DLL_PROCESS_DETACH) {
g_testRunning.store(false, std::memory_order_release);
}
return TRUE;
}