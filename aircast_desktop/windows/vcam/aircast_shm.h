#pragma once

#define NOMINMAX
#include <windows.h>
#include <sddl.h>
#include <atomic>
#include <cstdint>
#include <cstring>

namespace aircast {

    constexpr uint32_t kShmMagic = 0x31564341; // 'ACV1'
    constexpr uint32_t kShmVersion = 1;
    constexpr uint32_t kVcamWidth = 1280;
    constexpr uint32_t kVcamHeight = 720;
    constexpr uint32_t kVcamBytesPerPixel = 4; // Top-down BGRA32
    constexpr uint32_t kVcamStride = kVcamWidth * kVcamBytesPerPixel;
    constexpr uint32_t kVcamFrameBytes = kVcamStride * kVcamHeight;
    constexpr uint32_t kShmSlotCount = 3;      // Triple buffer: Writing / Published / Reading

    constexpr wchar_t kShmMappingName[] = L"Local\\AirCastVideoShm_v1";
    constexpr wchar_t kShmEventName[]   = L"Local\\AirCastVideoEvt_v1";

// {7A4E9C12-5B8D-4F3A-9C61-2D8F4B1E6A30}
    static constexpr GUID CLSID_AirCastVcam = {
            0x7a4e9c12, 0x5b8d, 0x4f3a,
            {0x9c, 0x61, 0x2d, 0x8f, 0x4b, 0x1e, 0x6a, 0x30}
    };
    constexpr wchar_t kVcamClsidStr[] = L"{7A4E9C12-5B8D-4F3A-9C61-2D8F4B1E6A30}";
    constexpr wchar_t kVcamFriendlyName[] = L"AirCast Camera";

    struct alignas(64) ShmHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t slotCount;
    std::atomic<uint32_t> publishedSlot;    // 0, 1, or 2
    std::atomic<uint32_t> writerActive;     // 1 while desktop writer is alive
    std::atomic<uint64_t> sequence;         // Increments on every published frame
    std::atomic<uint64_t> captureTimestampMs;
    std::atomic<uint64_t> writerHeartbeatMs;
    uint8_t reserved[8];
};

struct SharedVideoMemory {
    ShmHeader header;
    alignas(64) uint8_t slots[kShmSlotCount][kVcamFrameBytes];
};

inline bool createPermissiveSecurityAttributes(SECURITY_ATTRIBUTES& sa,
                                               PSECURITY_DESCRIPTOR& outSd,
                                               bool forEvent) {
    outSd = nullptr;
    // Grants SYSTEM, Admins, Interactive User full control;
    // Everyone + ALL APPLICATION PACKAGES (S-1-15-2-1) + RESTRICTED APP PACKAGES (S-1-15-2-2)
    // read access (+ SYNCHRONIZE via GX for events) + Low Mandatory Level for Chrome sandbox.
    const wchar_t* sddlPrimary = forEvent
                                 ? L"D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;IU)(A;;GRGX;;;WD)(A;;GRGX;;;S-1-15-2-1)(A;;GRGX;;;S-1-15-2-2)S:(ML;;NW;;;LW)"
                                 : L"D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;IU)(A;;GR;;;WD)(A;;GR;;;S-1-15-2-1)(A;;GR;;;S-1-15-2-2)S:(ML;;NW;;;LW)";

    const wchar_t* sddlFallback = forEvent
                                  ? L"D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;IU)(A;;GRGX;;;WD)(A;;GRGX;;;S-1-15-2-1)"
                                  : L"D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;IU)(A;;GR;;;WD)(A;;GR;;;S-1-15-2-1)";

    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddlPrimary, SDDL_REVISION_1, &outSd, nullptr)) {
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddlFallback, SDDL_REVISION_1, &outSd, nullptr)) {
            return false;
        }
    }

    sa.nLength = sizeof(SECURITY_ATTRIBUTES);
    sa.lpSecurityDescriptor = outSd;
    sa.bInheritHandle = FALSE;
    return true;
}

class ShmWriter {
public:
    ~ShmWriter() { close(); }

    bool open() {
        if (mem_ != nullptr) return true;

        SECURITY_ATTRIBUTES mapSa{};
        PSECURITY_DESCRIPTOR mapSd = nullptr;
        const bool hasMapSa = createPermissiveSecurityAttributes(mapSa, mapSd, false);

        const DWORD totalSize = static_cast<DWORD>(sizeof(SharedVideoMemory));
        mapping_ = CreateFileMappingW(
                INVALID_HANDLE_VALUE,
                hasMapSa ? &mapSa : nullptr,
                PAGE_READWRITE,
                0,
                totalSize,
                kShmMappingName);
        if (mapSd != nullptr) LocalFree(mapSd);
        if (mapping_ == nullptr) return false;

        void* view = MapViewOfFile(mapping_, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(SharedVideoMemory));
        if (view == nullptr) {
            close();
            return false;
        }
        mem_ = static_cast<SharedVideoMemory*>(view);

        SECURITY_ATTRIBUTES evtSa{};
        PSECURITY_DESCRIPTOR evtSd = nullptr;
        const bool hasEvtSa = createPermissiveSecurityAttributes(evtSa, evtSd, true);
        event_ = CreateEventW(hasEvtSa ? &evtSa : nullptr, FALSE, FALSE, kShmEventName);
        if (evtSd != nullptr) LocalFree(evtSd);

        mem_->header.magic = kShmMagic;
        mem_->header.version = kShmVersion;
        mem_->header.width = kVcamWidth;
        mem_->header.height = kVcamHeight;
        mem_->header.stride = kVcamStride;
        mem_->header.slotCount = kShmSlotCount;
        mem_->header.publishedSlot.store(0, std::memory_order_relaxed);
        mem_->header.sequence.store(0, std::memory_order_relaxed);
        mem_->header.captureTimestampMs.store(0, std::memory_order_relaxed);
        mem_->header.writerHeartbeatMs.store(GetTickCount64(), std::memory_order_relaxed);
        mem_->header.writerActive.store(1, std::memory_order_release);
        nextSlot_ = 1;
        return true;
    }

    /// Returns pointer to an unpublished 1280x720 BGRA32 buffer (always safe to write).
    uint8_t* acquireWriteSlot() {
        if (mem_ == nullptr) return nullptr;
        return mem_->slots[nextSlot_];
    }

    /// Atomically publishes the filled slot and wakes waiting readers.
    void commitWriteSlot(uint64_t captureTimestampMs) {
        if (mem_ == nullptr) return;
        const uint32_t slotToPublish = nextSlot_;
        nextSlot_ = (nextSlot_ + 1) % kShmSlotCount;

        mem_->header.captureTimestampMs.store(captureTimestampMs, std::memory_order_relaxed);
        mem_->header.writerHeartbeatMs.store(GetTickCount64(), std::memory_order_relaxed);
        mem_->header.publishedSlot.store(slotToPublish, std::memory_order_release);
        mem_->header.sequence.fetch_add(1, std::memory_order_acq_rel);
        mem_->header.writerActive.store(1, std::memory_order_release);

        if (event_ != nullptr) {
            SetEvent(event_);
        }
    }

    void markIdle() {
        if (mem_ == nullptr) return;
        mem_->header.writerActive.store(0, std::memory_order_release);
    }

    void close() {
        if (mem_ != nullptr) {
            mem_->header.writerActive.store(0, std::memory_order_release);
            UnmapViewOfFile(mem_);
            mem_ = nullptr;
        }
        if (event_ != nullptr) {
            CloseHandle(event_);
            event_ = nullptr;
        }
        if (mapping_ != nullptr) {
            CloseHandle(mapping_);
            mapping_ = nullptr;
        }
    }

    uint64_t sequence() const {
        return mem_ ? mem_->header.sequence.load(std::memory_order_acquire) : 0;
    }

private:
    HANDLE mapping_ = nullptr;
    HANDLE event_ = nullptr;
    SharedVideoMemory* mem_ = nullptr;
    uint32_t nextSlot_ = 1;
};

class ShmReader {
public:
    ~ShmReader() { close(); }

    bool ensureOpen() {
        if (mem_ != nullptr) return true;
        mapping_ = OpenFileMappingW(FILE_MAP_READ, FALSE, kShmMappingName);
        if (mapping_ == nullptr) return false;

        const void* view = MapViewOfFile(mapping_, FILE_MAP_READ, 0, 0, sizeof(SharedVideoMemory));
        if (view == nullptr) {
            close();
            return false;
        }

        const auto* candidate = static_cast<const SharedVideoMemory*>(view);
        if (candidate->header.magic != kShmMagic ||
            candidate->header.version != kShmVersion ||
            candidate->header.width != kVcamWidth ||
            candidate->header.height != kVcamHeight) {
            UnmapViewOfFile(view);
            close();
            return false;
        }

        mem_ = candidate;
        event_ = OpenEventW(SYNCHRONIZE, FALSE, kShmEventName);
        return true;
    }

    void waitForFrame(DWORD timeoutMs) {
        if (event_ != nullptr) {
            WaitForSingleObject(event_, timeoutMs);
        } else {
            Sleep(timeoutMs);
        }
    }

    /// Copies the latest published BGRA32 frame if writer is active & fresh (< 1500 ms stale).
    /// Returns true if a live frame was copied, false if offline/stale.
    bool readLatestBgra(uint8_t* dstBgra, uint64_t& outSeq) {
        if (!ensureOpen() || mem_ == nullptr) return false;

        if (mem_->header.writerActive.load(std::memory_order_acquire) == 0) {
            return false;
        }

        const uint64_t now = GetTickCount64();
        const uint64_t heartbeat = mem_->header.writerHeartbeatMs.load(std::memory_order_acquire);
        if (now > heartbeat && (now - heartbeat) > 1500) {
            return false;
        }

        const uint64_t seqBefore = mem_->header.sequence.load(std::memory_order_acquire);
        if (seqBefore == 0) return false;

        const uint32_t slot = mem_->header.publishedSlot.load(std::memory_order_acquire) % kShmSlotCount;
        std::memcpy(dstBgra, mem_->slots[slot], kVcamFrameBytes);
        outSeq = seqBefore;
        return true;
    }

    void close() {
        if (mem_ != nullptr) {
            UnmapViewOfFile(mem_);
            mem_ = nullptr;
        }
        if (event_ != nullptr) {
            CloseHandle(event_);
            event_ = nullptr;
        }
        if (mapping_ != nullptr) {
            CloseHandle(mapping_);
            mapping_ = nullptr;
        }
    }

private:
    HANDLE mapping_ = nullptr;
    HANDLE event_ = nullptr;
    const SharedVideoMemory* mem_ = nullptr;
};

} // namespace aircast