#define NOMINMAX
#include <string>
#include <windows.h>
#include <dshow.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmsystem.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <thread>
#include <vector>

#include "aircast_shm.h"

namespace {

    HMODULE g_hModule = nullptr;
    std::atomic<LONG> g_dllRefCount{0};

    constexpr REFERENCE_TIME kFrameInterval30Fps = 333333; // 30.000 FPS in 100ns units

// ---------------------------------------------------------------------------
// COM AM_MEDIA_TYPE helpers (no external DirectShow BaseClasses required)
// ---------------------------------------------------------------------------
    void clearMediaType(AM_MEDIA_TYPE& mt) {
        if (mt.cbFormat != 0 && mt.pbFormat != nullptr) {
            CoTaskMemFree(mt.pbFormat);
            mt.pbFormat = nullptr;
            mt.cbFormat = 0;
        }
        if (mt.pUnk != nullptr) {
            mt.pUnk->Release();
            mt.pUnk = nullptr;
        }
    }

    void deleteMediaType(AM_MEDIA_TYPE* pmt) {
        if (pmt != nullptr) {
            clearMediaType(*pmt);
            CoTaskMemFree(pmt);
        }
    }

    HRESULT copyMediaType(AM_MEDIA_TYPE* dst, const AM_MEDIA_TYPE* src) {
        if (!dst || !src) return E_POINTER;
        *dst = *src;
        dst->pbFormat = nullptr;
        dst->pUnk = nullptr;
        if (src->cbFormat != 0 && src->pbFormat != nullptr) {
            dst->pbFormat = static_cast<BYTE*>(CoTaskMemAlloc(src->cbFormat));
            if (!dst->pbFormat) {
                dst->cbFormat = 0;
                return E_OUTOFMEMORY;
            }
            std::memcpy(dst->pbFormat, src->pbFormat, src->cbFormat);
        }
        if (src->pUnk != nullptr) {
            src->pUnk->AddRef();
            dst->pUnk = src->pUnk;
        }
        return S_OK;
    }

    AM_MEDIA_TYPE* allocMediaType(const AM_MEDIA_TYPE* src) {
        auto* pmt = static_cast<AM_MEDIA_TYPE*>(CoTaskMemAlloc(sizeof(AM_MEDIA_TYPE)));
        if (!pmt) return nullptr;
        std::memset(pmt, 0, sizeof(AM_MEDIA_TYPE));
        if (src != nullptr && FAILED(copyMediaType(pmt, src))) {
            CoTaskMemFree(pmt);
            return nullptr;
        }
        return pmt;
    }

// index 0 = YUY2 1280x720@30fps, index 1 = RGB24 1280x720@30fps
    bool buildSupportedMediaType(int index, AM_MEDIA_TYPE& mt) {
        std::memset(&mt, 0, sizeof(mt));
        if (index != 0 && index != 1) return false;

        auto* vih = static_cast<VIDEOINFOHEADER*>(CoTaskMemAlloc(sizeof(VIDEOINFOHEADER)));
        if (!vih) return false;
        std::memset(vih, 0, sizeof(VIDEOINFOHEADER));

        const bool isYuy2 = (index == 0);
        const WORD bitCount = isYuy2 ? 16 : 24;
        const DWORD imageSize = aircast::kVcamWidth * aircast::kVcamHeight * (bitCount / 8);

        vih->rcSource = {0, 0, static_cast<LONG>(aircast::kVcamWidth), static_cast<LONG>(aircast::kVcamHeight)};
        vih->rcTarget = vih->rcSource;
        vih->dwBitRate = imageSize * 8 * 30;
        vih->AvgTimePerFrame = kFrameInterval30Fps;

        vih->bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        vih->bmiHeader.biWidth = static_cast<LONG>(aircast::kVcamWidth);
        vih->bmiHeader.biHeight = static_cast<LONG>(aircast::kVcamHeight); // YUY2 is top-down regardless; RGB24 bottom-up
        vih->bmiHeader.biPlanes = 1;
        vih->bmiHeader.biBitCount = bitCount;
        vih->bmiHeader.biCompression = isYuy2 ? MAKEFOURCC('Y', 'U', 'Y', '2') : BI_RGB;
        vih->bmiHeader.biSizeImage = imageSize;

        mt.majortype = MEDIATYPE_Video;
        mt.subtype = isYuy2 ? MEDIASUBTYPE_YUY2 : MEDIASUBTYPE_RGB24;
        mt.bFixedSizeSamples = TRUE;
        mt.bTemporalCompression = FALSE;
        mt.lSampleSize = imageSize;
        mt.formattype = FORMAT_VideoInfo;
        mt.cbFormat = sizeof(VIDEOINFOHEADER);
        mt.pbFormat = reinterpret_cast<BYTE*>(vih);
        return true;
    }

    bool isMediaTypeSupported(const AM_MEDIA_TYPE* pmt) {
        if (!pmt) return false;
        if (pmt->majortype != MEDIATYPE_Video) return false;
        if (pmt->formattype != FORMAT_VideoInfo || pmt->cbFormat < sizeof(VIDEOINFOHEADER) || !pmt->pbFormat) {
            return false;
        }

        const bool isYuy2 = (pmt->subtype == MEDIASUBTYPE_YUY2);
        const bool isRgb24 = (pmt->subtype == MEDIASUBTYPE_RGB24);
        if (!isYuy2 && !isRgb24) return false;

        const auto* vih = reinterpret_cast<const VIDEOINFOHEADER*>(pmt->pbFormat);
        const LONG w = vih->bmiHeader.biWidth;
        const LONG h = std::abs(vih->bmiHeader.biHeight);
        if (w < static_cast<LONG>(aircast::kVcamWidth) || h != static_cast<LONG>(aircast::kVcamHeight)) {
            return false;
        }
        if (isYuy2 && vih->bmiHeader.biBitCount != 16) return false;
        if (isRgb24 && vih->bmiHeader.biBitCount != 24) return false;
        return true;
    }

// ---------------------------------------------------------------------------
// Pixel converters & standby slate (BGRA32 -> YUY2 / RGB24)
// ---------------------------------------------------------------------------
    inline uint8_t clampU8(int v) {
        return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
    }

    void renderStandbySlateBgra(uint8_t* bgra, uint64_t frameIdx) {
        constexpr uint32_t W = aircast::kVcamWidth;
        constexpr uint32_t H = aircast::kVcamHeight;
        const uint32_t scanX = static_cast<uint32_t>((frameIdx * 10) % W);

        for (uint32_t y = 0; y < H; ++y) {
            uint8_t* row = bgra + y * aircast::kVcamStride;
            const bool inCenterBand = (y >= H / 2 - 48 && y <= H / 2 + 48);
            const bool isBorder = (y == H / 2 - 48 || y == H / 2 + 48);

            for (uint32_t x = 0; x < W; ++x) {
                uint8_t b = 22, g = 18, r = 18;
                if (isBorder && x >= W / 2 - 220 && x <= W / 2 + 220) {
                    r = 255; g = 115; b = 29; // PixelPlot / AirCast orange accent
                } else if (inCenterBand && x >= W / 2 - 220 && x <= W / 2 + 220) {
                    r = 28; g = 28; b = 34;
                    const uint32_t dist = (x > scanX) ? (x - scanX) : (scanX - x);
                    if (dist < 14) {
                        r = 255; g = 125; b = 40;
                    }
                }
                row[x * 4 + 0] = b;
                row[x * 4 + 1] = g;
                row[x * 4 + 2] = r;
                row[x * 4 + 3] = 255;
            }
        }
    }

    void convertBgraToYuy2(const uint8_t* srcBgra, uint8_t* dst, LONG dstPixelWidth) {
        constexpr uint32_t W = aircast::kVcamWidth;
        constexpr uint32_t H = aircast::kVcamHeight;
        const size_t dstStride = static_cast<size_t>(dstPixelWidth) * 2;

        for (uint32_t y = 0; y < H; ++y) {
            const uint8_t* s = srcBgra + y * aircast::kVcamStride;
            uint8_t* d = dst + y * dstStride;
            for (uint32_t x = 0; x < W; x += 2) {
                const int b0 = s[0], g0 = s[1], r0 = s[2];
                const int b1 = s[4], g1 = s[5], r1 = s[6];

                const int y0 = ((66 * r0 + 129 * g0 + 25 * b0 + 128) >> 8) + 16;
                const int y1 = ((66 * r1 + 129 * g1 + 25 * b1 + 128) >> 8) + 16;

                const int rAvg = (r0 + r1) >> 1;
                const int gAvg = (g0 + g1) >> 1;
                const int bAvg = (b0 + b1) >> 1;
                const int u = ((-38 * rAvg - 74 * gAvg + 112 * bAvg + 128) >> 8) + 128;
                const int v = ((112 * rAvg - 94 * gAvg - 18 * bAvg + 128) >> 8) + 128;

                d[0] = clampU8(y0);
                d[1] = clampU8(u);
                d[2] = clampU8(y1);
                d[3] = clampU8(v);
                s += 8;
                d += 4;
            }
        }
    }

    void convertBgraToRgb24(const uint8_t* srcBgra, uint8_t* dst, LONG dstPixelWidth, bool bottomUp) {
        constexpr uint32_t W = aircast::kVcamWidth;
        constexpr uint32_t H = aircast::kVcamHeight;
        const size_t dstStride = ((static_cast<size_t>(dstPixelWidth) * 3) + 3) & ~static_cast<size_t>(3);

        for (uint32_t y = 0; y < H; ++y) {
            const uint32_t srcY = bottomUp ? (H - 1 - y) : y;
            const uint8_t* s = srcBgra + srcY * aircast::kVcamStride;
            uint8_t* d = dst + y * dstStride;
            for (uint32_t x = 0; x < W; ++x) {
                d[0] = s[0]; // B
                d[1] = s[1]; // G
                d[2] = s[2]; // R
                s += 4;
                d += 3;
            }
        }
    }

    class AirCastVcamFilter;

// ---------------------------------------------------------------------------
// IEnumMediaTypes
// ---------------------------------------------------------------------------
    class AirCastEnumMediaTypes final : public IEnumMediaTypes {
    public:
        explicit AirCastEnumMediaTypes(int pos = 0) : ref_(1), pos_(pos) {
            g_dllRefCount.fetch_add(1, std::memory_order_relaxed);
        }
        ~AirCastEnumMediaTypes() {
            g_dllRefCount.fetch_sub(1, std::memory_order_relaxed);
        }

        STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
            if (!ppv) return E_POINTER;
            if (riid == IID_IUnknown || riid == IID_IEnumMediaTypes) {
                *ppv = static_cast<IEnumMediaTypes*>(this);
                AddRef();
                return S_OK;
            }
            *ppv = nullptr;
            return E_NOINTERFACE;
        }
        STDMETHODIMP_(ULONG) AddRef() override { return ++ref_; }
        STDMETHODIMP_(ULONG) Release() override {
            const ULONG r = --ref_;
            if (r == 0) delete this;
            return r;
        }

        STDMETHODIMP Next(ULONG cMediaTypes, AM_MEDIA_TYPE** ppMediaTypes, ULONG* pcFetched) override {
            if (!ppMediaTypes) return E_POINTER;
            if (cMediaTypes != 1 && !pcFetched) return E_POINTER;

            ULONG fetched = 0;
            while (fetched < cMediaTypes && pos_ < 2) {
                AM_MEDIA_TYPE tmp{};
                if (!buildSupportedMediaType(pos_, tmp)) break;
                ppMediaTypes[fetched] = allocMediaType(&tmp);
                clearMediaType(tmp);
                if (!ppMediaTypes[fetched]) return E_OUTOFMEMORY;
                ++fetched;
                ++pos_;
            }
            if (pcFetched) *pcFetched = fetched;
            return (fetched == cMediaTypes) ? S_OK : S_FALSE;
        }
        STDMETHODIMP Skip(ULONG cMediaTypes) override {
            pos_ += static_cast<int>(cMediaTypes);
            return (pos_ <= 2) ? S_OK : S_FALSE;
        }
        STDMETHODIMP Reset() override { pos_ = 0; return S_OK; }
        STDMETHODIMP Clone(IEnumMediaTypes** ppEnum) override {
            if (!ppEnum) return E_POINTER;
            *ppEnum = new AirCastEnumMediaTypes(pos_);
            return S_OK;
        }

    private:
        std::atomic<ULONG> ref_;
        int pos_;
    };

// ---------------------------------------------------------------------------
// Output Pin (IPin + IAMStreamConfig + IKsPropertySet + IQualityControl)
// ---------------------------------------------------------------------------
    class AirCastVcamPin final : public IPin,
                                 public IAMStreamConfig,
                                 public IKsPropertySet,
                                 public IQualityControl {
    public:
        explicit AirCastVcamPin(AirCastVcamFilter* filter);
        ~AirCastVcamPin();

        // IUnknown (delegated to filter lifetime or refcounted directly)
        STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
        STDMETHODIMP_(ULONG) AddRef() override;
        STDMETHODIMP_(ULONG) Release() override;

        // IPin
        STDMETHODIMP Connect(IPin* pReceivePin, const AM_MEDIA_TYPE* pmt) override;
        STDMETHODIMP ReceiveConnection(IPin*, const AM_MEDIA_TYPE*) override { return E_UNEXPECTED; }
        STDMETHODIMP Disconnect() override;
        STDMETHODIMP ConnectedTo(IPin** pPin) override;
        STDMETHODIMP ConnectionMediaType(AM_MEDIA_TYPE* pmt) override;
        STDMETHODIMP QueryPinInfo(PIN_INFO* pInfo) override;
        STDMETHODIMP QueryDirection(PIN_DIRECTION* pPinDir) override {
            if (!pPinDir) return E_POINTER;
            *pPinDir = PINDIR_OUTPUT;
            return S_OK;
        }
        STDMETHODIMP QueryId(LPWSTR* Id) override {
            if (!Id) return E_POINTER;
            const wchar_t* name = L"Capture";
            const size_t bytes = (std::wcslen(name) + 1) * sizeof(wchar_t);
            *Id = static_cast<LPWSTR>(CoTaskMemAlloc(bytes));
            if (!*Id) return E_OUTOFMEMORY;
            std::memcpy(*Id, name, bytes);
            return S_OK;
        }
        STDMETHODIMP QueryAccept(const AM_MEDIA_TYPE* pmt) override {
            return isMediaTypeSupported(pmt) ? S_OK : S_FALSE;
        }
        STDMETHODIMP EnumMediaTypes(IEnumMediaTypes** ppEnum) override {
            if (!ppEnum) return E_POINTER;
            *ppEnum = new AirCastEnumMediaTypes(0);
            return S_OK;
        }
        STDMETHODIMP QueryInternalConnections(IPin**, ULONG*) override { return E_NOTIMPL; }
        STDMETHODIMP EndOfStream() override { return E_UNEXPECTED; }
        STDMETHODIMP BeginFlush() override { return E_UNEXPECTED; }
        STDMETHODIMP EndFlush() override { return E_UNEXPECTED; }
        STDMETHODIMP NewSegment(REFERENCE_TIME, REFERENCE_TIME, double) override { return S_OK; }

        // IAMStreamConfig
        STDMETHODIMP SetFormat(AM_MEDIA_TYPE* pmt) override;
        STDMETHODIMP GetFormat(AM_MEDIA_TYPE** ppmt) override;
        STDMETHODIMP GetNumberOfCapabilities(int* piCount, int* piSize) override {
            if (!piCount || !piSize) return E_POINTER;
            *piCount = 2;
            *piSize = sizeof(VIDEO_STREAM_CONFIG_CAPS);
            return S_OK;
        }
        STDMETHODIMP GetStreamCaps(int iIndex, AM_MEDIA_TYPE** ppmt, BYTE* pSCC) override;

        // IKsPropertySet
        STDMETHODIMP Set(REFGUID, DWORD, LPVOID, DWORD, LPVOID, DWORD) override { return E_NOTIMPL; }
        STDMETHODIMP Get(REFGUID guidPropSet, DWORD dwPropID, LPVOID, DWORD,
                         LPVOID pPropData, DWORD cbPropData, DWORD* pcbReturned) override {
            if (guidPropSet != AMPROPSETID_Pin) return E_PROP_SET_UNSUPPORTED;
            if (dwPropID != AMPROPERTY_PIN_CATEGORY) return E_PROP_ID_UNSUPPORTED;
            if (pPropData == nullptr && pcbReturned == nullptr) return E_POINTER;
            if (pcbReturned) *pcbReturned = sizeof(GUID);
            if (pPropData == nullptr) return S_OK;
            if (cbPropData < sizeof(GUID)) return E_UNEXPECTED;
            *static_cast<GUID*>(pPropData) = PIN_CATEGORY_CAPTURE;
            return S_OK;
        }
        STDMETHODIMP QuerySupported(REFGUID guidPropSet, DWORD dwPropID, DWORD* pTypeSupport) override {
            if (guidPropSet != AMPROPSETID_Pin) return E_PROP_SET_UNSUPPORTED;
            if (dwPropID != AMPROPERTY_PIN_CATEGORY) return E_PROP_ID_UNSUPPORTED;
            if (pTypeSupport) *pTypeSupport = KSPROPERTY_SUPPORT_GET;
            return S_OK;
        }

        // IQualityControl
        STDMETHODIMP Notify(IBaseFilter*, Quality) override { return S_OK; }
        STDMETHODIMP SetSink(IQualityControl*) override { return S_OK; }

        // Lifecycle called by parent filter
        HRESULT startStreaming();
        HRESULT stopStreaming();

    private:
        HRESULT negotiateAllocator(IMemInputPin* memIn, const AM_MEDIA_TYPE& mt);
        void streamLoop();

        AirCastVcamFilter* filter_;
        std::mutex mutex_;
        IPin* connectedPin_ = nullptr;
        IMemInputPin* memInputPin_ = nullptr;
        IMemAllocator* allocator_ = nullptr;

        AM_MEDIA_TYPE preferredMt_{};
        AM_MEDIA_TYPE connectedMt_{};
        bool hasPreferredMt_ = false;
        bool hasConnectedMt_ = false;

        std::atomic<bool> streaming_{false};
        std::thread thread_;
    };

// ---------------------------------------------------------------------------
// IEnumPins
// ---------------------------------------------------------------------------
    class AirCastEnumPins final : public IEnumPins {
    public:
        AirCastEnumPins(AirCastVcamPin* pin, int pos = 0) : ref_(1), pin_(pin), pos_(pos) {
            if (pin_) pin_->AddRef();
            g_dllRefCount.fetch_add(1, std::memory_order_relaxed);
        }
        ~AirCastEnumPins() {
            if (pin_) pin_->Release();
            g_dllRefCount.fetch_sub(1, std::memory_order_relaxed);
        }

        STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
            if (!ppv) return E_POINTER;
            if (riid == IID_IUnknown || riid == IID_IEnumPins) {
                *ppv = static_cast<IEnumPins*>(this);
                AddRef();
                return S_OK;
            }
            *ppv = nullptr;
            return E_NOINTERFACE;
        }
        STDMETHODIMP_(ULONG) AddRef() override { return ++ref_; }
        STDMETHODIMP_(ULONG) Release() override {
            const ULONG r = --ref_;
            if (r == 0) delete this;
            return r;
        }

        STDMETHODIMP Next(ULONG cPins, IPin** ppPins, ULONG* pcFetched) override {
            if (!ppPins) return E_POINTER;
            if (cPins != 1 && !pcFetched) return E_POINTER;
            ULONG fetched = 0;
            if (pos_ == 0 && cPins > 0 && pin_) {
                ppPins[0] = static_cast<IPin*>(pin_);
                ppPins[0]->AddRef();
                fetched = 1;
                pos_ = 1;
            }
            if (pcFetched) *pcFetched = fetched;
            return (fetched == cPins) ? S_OK : S_FALSE;
        }
        STDMETHODIMP Skip(ULONG cPins) override {
            pos_ += static_cast<int>(cPins);
            return (pos_ <= 1) ? S_OK : S_FALSE;
        }
        STDMETHODIMP Reset() override { pos_ = 0; return S_OK; }
        STDMETHODIMP Clone(IEnumPins** ppEnum) override {
            if (!ppEnum) return E_POINTER;
            *ppEnum = new AirCastEnumPins(pin_, pos_);
            return S_OK;
        }

    private:
        std::atomic<ULONG> ref_;
        AirCastVcamPin* pin_;
        int pos_;
    };

// ---------------------------------------------------------------------------
// Main Filter (IBaseFilter + IAMFilterMiscFlags)
// ---------------------------------------------------------------------------
    class AirCastVcamFilter final : public IBaseFilter, public IAMFilterMiscFlags {
    public:
        AirCastVcamFilter() : ref_(1), pin_(this) {
            g_dllRefCount.fetch_add(1, std::memory_order_relaxed);
            std::wcsncpy(name_, aircast::kVcamFriendlyName, MAX_FILTER_NAME - 1);
        }
        ~AirCastVcamFilter() {
            pin_.stopStreaming();
            if (clock_) clock_->Release();
            g_dllRefCount.fetch_sub(1, std::memory_order_relaxed);
        }

        STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
            if (!ppv) return E_POINTER;
            if (riid == IID_IUnknown || riid == IID_IPersist ||
                riid == IID_IMediaFilter || riid == IID_IBaseFilter) {
                *ppv = static_cast<IBaseFilter*>(this);
                AddRef();
                return S_OK;
            }
            if (riid == IID_IAMFilterMiscFlags) {
                *ppv = static_cast<IAMFilterMiscFlags*>(this);
                AddRef();
                return S_OK;
            }
            *ppv = nullptr;
            return E_NOINTERFACE;
        }
        STDMETHODIMP_(ULONG) AddRef() override { return ++ref_; }
        STDMETHODIMP_(ULONG) Release() override {
            const ULONG r = --ref_;
            if (r == 0) delete this;
            return r;
        }

        // IPersist
        STDMETHODIMP GetClassID(CLSID* pClsID) override {
            if (!pClsID) return E_POINTER;
            *pClsID = aircast::CLSID_AirCastVcam;
            return S_OK;
        }

        // IMediaFilter
        STDMETHODIMP Stop() override {
            std::lock_guard<std::mutex> lock(stateMutex_);
            if (state_ != State_Stopped) {
                pin_.stopStreaming();
                state_ = State_Stopped;
            }
            return S_OK;
        }
        STDMETHODIMP Pause() override {
            std::lock_guard<std::mutex> lock(stateMutex_);
            if (state_ == State_Stopped) {
                const HRESULT hr = pin_.startStreaming();
                if (FAILED(hr)) return hr;
            }
            state_ = State_Paused;
            return S_OK;
        }
        STDMETHODIMP Run(REFERENCE_TIME) override {
            std::lock_guard<std::mutex> lock(stateMutex_);
            if (state_ == State_Stopped) {
                const HRESULT hr = pin_.startStreaming();
                if (FAILED(hr)) return hr;
            }
            state_ = State_Running;
            return S_OK;
        }
        STDMETHODIMP GetState(DWORD, FILTER_STATE* pState) override {
            if (!pState) return E_POINTER;
            std::lock_guard<std::mutex> lock(stateMutex_);
            *pState = state_;
            return (state_ == State_Paused) ? VFW_S_CANT_CUE : S_OK;
        }
        STDMETHODIMP SetSyncSource(IReferenceClock* pClock) override {
            std::lock_guard<std::mutex> lock(stateMutex_);
            if (clock_) clock_->Release();
            clock_ = pClock;
            if (clock_) clock_->AddRef();
            return S_OK;
        }
        STDMETHODIMP GetSyncSource(IReferenceClock** pClock) override {
            if (!pClock) return E_POINTER;
            std::lock_guard<std::mutex> lock(stateMutex_);
            *pClock = clock_;
            if (clock_) clock_->AddRef();
            return S_OK;
        }

        // IBaseFilter
        STDMETHODIMP EnumPins(IEnumPins** ppEnum) override {
            if (!ppEnum) return E_POINTER;
            *ppEnum = new AirCastEnumPins(&pin_, 0);
            return S_OK;
        }
        STDMETHODIMP FindPin(LPCWSTR Id, IPin** ppPin) override {
            if (!ppPin) return E_POINTER;
            if (Id && std::wcscmp(Id, L"Capture") == 0) {
                *ppPin = static_cast<IPin*>(&pin_);
                (*ppPin)->AddRef();
                return S_OK;
            }
            *ppPin = nullptr;
            return VFW_E_NOT_FOUND;
        }
        STDMETHODIMP QueryFilterInfo(FILTER_INFO* pInfo) override {
            if (!pInfo) return E_POINTER;
            std::lock_guard<std::mutex> lock(stateMutex_);
            std::wcsncpy(pInfo->achName, name_, MAX_FILTER_NAME - 1);
            pInfo->achName[MAX_FILTER_NAME - 1] = L'\0';
            pInfo->pGraph = graph_;
            if (graph_) graph_->AddRef();
            return S_OK;
        }
        STDMETHODIMP JoinFilterGraph(IFilterGraph* pGraph, LPCWSTR pName) override {
            std::lock_guard<std::mutex> lock(stateMutex_);
            graph_ = pGraph; // Weak reference per DirectShow spec (do NOT AddRef)
            if (pName) {
                std::wcsncpy(name_, pName, MAX_FILTER_NAME - 1);
                name_[MAX_FILTER_NAME - 1] = L'\0';
            }
            return S_OK;
        }
        STDMETHODIMP QueryVendorInfo(LPWSTR* pVendorInfo) override {
            if (!pVendorInfo) return E_POINTER;
            const wchar_t* vendor = L"PixelPlot AirCast";
            const size_t bytes = (std::wcslen(vendor) + 1) * sizeof(wchar_t);
            *pVendorInfo = static_cast<LPWSTR>(CoTaskMemAlloc(bytes));
            if (!*pVendorInfo) return E_OUTOFMEMORY;
            std::memcpy(*pVendorInfo, vendor, bytes);
            return S_OK;
        }

        // IAMFilterMiscFlags
        STDMETHODIMP_(ULONG) GetMiscFlags() override {
            return AM_FILTER_MISC_FLAGS_IS_SOURCE;
        }

        bool isStopped() const {
            std::lock_guard<std::mutex> lock(stateMutex_);
            return state_ == State_Stopped;
        }

    private:
        std::atomic<ULONG> ref_;
        mutable std::mutex stateMutex_;
        FILTER_STATE state_ = State_Stopped;
        IFilterGraph* graph_ = nullptr;
        IReferenceClock* clock_ = nullptr;
        WCHAR name_[MAX_FILTER_NAME]{};
        AirCastVcamPin pin_;
    };

// ---------------------------------------------------------------------------
// AirCastVcamPin implementation
// ---------------------------------------------------------------------------
    AirCastVcamPin::AirCastVcamPin(AirCastVcamFilter* filter) : filter_(filter) {
        if (buildSupportedMediaType(0, preferredMt_)) {
            hasPreferredMt_ = true;
        }
    }

    AirCastVcamPin::~AirCastVcamPin() {
        stopStreaming();
        Disconnect();
        if (hasPreferredMt_) clearMediaType(preferredMt_);
        if (hasConnectedMt_) clearMediaType(connectedMt_);
    }

    STDMETHODIMP AirCastVcamPin::QueryInterface(REFIID riid, void** ppv) {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IPin) {
            *ppv = static_cast<IPin*>(this);
            AddRef();
            return S_OK;
        }
        if (riid == IID_IAMStreamConfig) {
            *ppv = static_cast<IAMStreamConfig*>(this);
            AddRef();
            return S_OK;
        }
        if (riid == IID_IKsPropertySet) {
            *ppv = static_cast<IKsPropertySet*>(this);
            AddRef();
            return S_OK;
        }
        if (riid == IID_IQualityControl) {
            *ppv = static_cast<IQualityControl*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    STDMETHODIMP_(ULONG) AirCastVcamPin::AddRef() { return filter_->AddRef(); }
    STDMETHODIMP_(ULONG) AirCastVcamPin::Release() { return filter_->Release(); }

    STDMETHODIMP AirCastVcamPin::Connect(IPin* pReceivePin, const AM_MEDIA_TYPE* pmt) {
        if (!pReceivePin) return E_POINTER;
        std::lock_guard<std::mutex> lock(mutex_);
        if (connectedPin_) return VFW_E_ALREADY_CONNECTED;
        if (!filter_->isStopped()) return VFW_E_NOT_STOPPED;

        PIN_DIRECTION dir{};
        if (FAILED(pReceivePin->QueryDirection(&dir)) || dir != PINDIR_INPUT) {
            return VFW_E_INVALID_DIRECTION;
        }

        IMemInputPin* memIn = nullptr;
        if (FAILED(pReceivePin->QueryInterface(IID_IMemInputPin, reinterpret_cast<void**>(&memIn)))) {
            return VFW_E_NO_TRANSPORT;
        }

        auto tryType = [&](const AM_MEDIA_TYPE& candidate) -> HRESULT {
            if (!isMediaTypeSupported(&candidate)) return VFW_E_TYPE_NOT_ACCEPTED;
            HRESULT hr = pReceivePin->ReceiveConnection(this, &candidate);
            if (FAILED(hr)) return hr;
            hr = negotiateAllocator(memIn, candidate);
            if (FAILED(hr)) {
                pReceivePin->Disconnect();
                return hr;
            }
            if (hasConnectedMt_) clearMediaType(connectedMt_);
            copyMediaType(&connectedMt_, &candidate);
            hasConnectedMt_ = true;
            connectedPin_ = pReceivePin;
            connectedPin_->AddRef();
            memInputPin_ = memIn;
            memInputPin_->AddRef();
            return S_OK;
        };

        HRESULT hr = VFW_E_NO_ACCEPTABLE_TYPES;
        if (pmt && pmt->majortype != GUID_NULL && pmt->subtype != GUID_NULL &&
            pmt->formattype == FORMAT_VideoInfo && pmt->pbFormat != nullptr) {
            hr = tryType(*pmt);
        } else {
            // Try user-selected preferred format first, then YUY2, then RGB24
            if (hasPreferredMt_) {
                hr = tryType(preferredMt_);
            }
            for (int idx = 0; FAILED(hr) && idx < 2; ++idx) {
                AM_MEDIA_TYPE cand{};
                if (buildSupportedMediaType(idx, cand)) {
                    hr = tryType(cand);
                    clearMediaType(cand);
                }
            }
        }

        memIn->Release();
        return hr;
    }

    HRESULT AirCastVcamPin::negotiateAllocator(IMemInputPin* memIn, const AM_MEDIA_TYPE& mt) {
        if (allocator_) {
            allocator_->Release();
            allocator_ = nullptr;
        }

        IMemAllocator* pAlloc = nullptr;
        HRESULT hr = memIn->GetAllocator(&pAlloc);
        if (FAILED(hr) || !pAlloc) {
            hr = CoCreateInstance(CLSID_MemoryAllocator, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_IMemAllocator, reinterpret_cast<void**>(&pAlloc));
            if (FAILED(hr) || !pAlloc) return hr;
        }

        ALLOCATOR_PROPERTIES req{};
        memIn->GetAllocatorRequirements(&req);
        if (req.cBuffers < 2) req.cBuffers = 2;
        if (req.cbBuffer < static_cast<long>(mt.lSampleSize)) {
            req.cbBuffer = static_cast<long>(mt.lSampleSize);
        }
        if (req.cbAlign < 1) req.cbAlign = 1;

        ALLOCATOR_PROPERTIES actual{};
        hr = pAlloc->SetProperties(&req, &actual);
        if (SUCCEEDED(hr)) {
            hr = memIn->NotifyAllocator(pAlloc, FALSE);
        }
        if (SUCCEEDED(hr)) {
            allocator_ = pAlloc; // ownership transferred
        } else {
            pAlloc->Release();
        }
        return hr;
    }

    STDMETHODIMP AirCastVcamPin::Disconnect() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!filter_->isStopped()) return VFW_E_NOT_STOPPED;
        if (!connectedPin_) return S_FALSE;

        if (allocator_) {
            allocator_->Decommit();
            allocator_->Release();
            allocator_ = nullptr;
        }
        if (memInputPin_) {
            memInputPin_->Release();
            memInputPin_ = nullptr;
        }
        connectedPin_->Release();
        connectedPin_ = nullptr;
        if (hasConnectedMt_) {
            clearMediaType(connectedMt_);
            hasConnectedMt_ = false;
        }
        return S_OK;
    }

    STDMETHODIMP AirCastVcamPin::ConnectedTo(IPin** pPin) {
        if (!pPin) return E_POINTER;
        std::lock_guard<std::mutex> lock(mutex_);
        *pPin = connectedPin_;
        if (connectedPin_) {
            connectedPin_->AddRef();
            return S_OK;
        }
        return VFW_E_NOT_CONNECTED;
    }

    STDMETHODIMP AirCastVcamPin::ConnectionMediaType(AM_MEDIA_TYPE* pmt) {
        if (!pmt) return E_POINTER;
        std::lock_guard<std::mutex> lock(mutex_);
        if (!hasConnectedMt_) return VFW_E_NOT_CONNECTED;
        return copyMediaType(pmt, &connectedMt_);
    }

    STDMETHODIMP AirCastVcamPin::QueryPinInfo(PIN_INFO* pInfo) {
        if (!pInfo) return E_POINTER;
        pInfo->pFilter = static_cast<IBaseFilter*>(filter_);
        pInfo->pFilter->AddRef();
        pInfo->dir = PINDIR_OUTPUT;
        std::wcsncpy(pInfo->achName, L"Capture", MAX_PIN_NAME - 1);
        pInfo->achName[MAX_PIN_NAME - 1] = L'\0';
        return S_OK;
    }

    STDMETHODIMP AirCastVcamPin::SetFormat(AM_MEDIA_TYPE* pmt) {
        if (!pmt) return E_POINTER;
        if (!isMediaTypeSupported(pmt)) return VFW_E_INVALIDMEDIATYPE;
        std::lock_guard<std::mutex> lock(mutex_);
        if (!filter_->isStopped()) return VFW_E_NOT_STOPPED;
        if (hasPreferredMt_) clearMediaType(preferredMt_);
        const HRESULT hr = copyMediaType(&preferredMt_, pmt);
        hasPreferredMt_ = SUCCEEDED(hr);
        return hr;
    }

    STDMETHODIMP AirCastVcamPin::GetFormat(AM_MEDIA_TYPE** ppmt) {
        if (!ppmt) return E_POINTER;
        std::lock_guard<std::mutex> lock(mutex_);
        const AM_MEDIA_TYPE& src = hasConnectedMt_ ? connectedMt_ : preferredMt_;
        *ppmt = allocMediaType(&src);
        return (*ppmt) ? S_OK : E_OUTOFMEMORY;
    }

    STDMETHODIMP AirCastVcamPin::GetStreamCaps(int iIndex, AM_MEDIA_TYPE** ppmt, BYTE* pSCC) {
        if (!ppmt || !pSCC) return E_POINTER;
        if (iIndex < 0 || iIndex >= 2) return S_FALSE;

        AM_MEDIA_TYPE mt{};
        if (!buildSupportedMediaType(iIndex, mt)) return E_FAIL;
        *ppmt = allocMediaType(&mt);
        const DWORD sampleSize = mt.lSampleSize;
        clearMediaType(mt);
        if (!*ppmt) return E_OUTOFMEMORY;

        auto* caps = reinterpret_cast<VIDEO_STREAM_CONFIG_CAPS*>(pSCC);
        std::memset(caps, 0, sizeof(VIDEO_STREAM_CONFIG_CAPS));
        caps->guid = FORMAT_VideoInfo;
        caps->VideoStandard = 0;
        caps->InputSize = {static_cast<LONG>(aircast::kVcamWidth), static_cast<LONG>(aircast::kVcamHeight)};
        caps->MinCroppingSize = caps->InputSize;
        caps->MaxCroppingSize = caps->InputSize;
        caps->CropGranularityX = 1;
        caps->CropGranularityY = 1;
        caps->MinOutputSize = caps->InputSize;
        caps->MaxOutputSize = caps->InputSize;
        caps->OutputGranularityX = 1;
        caps->OutputGranularityY = 1;
        caps->MinFrameInterval = kFrameInterval30Fps;
        caps->MaxFrameInterval = kFrameInterval30Fps;
        caps->MinBitsPerSecond = static_cast<LONG>(sampleSize * 8 * 30);
        caps->MaxBitsPerSecond = static_cast<LONG>(sampleSize * 8 * 30);
        return S_OK;
    }

    HRESULT AirCastVcamPin::startStreaming() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!connectedPin_ || !memInputPin_ || !allocator_) return S_OK;
        if (streaming_.load(std::memory_order_acquire)) return S_OK;

        const HRESULT hr = allocator_->Commit();
        if (FAILED(hr)) return hr;

        streaming_.store(true, std::memory_order_release);
        thread_ = std::thread(&AirCastVcamPin::streamLoop, this);
        return S_OK;
    }

    HRESULT AirCastVcamPin::stopStreaming() {
        streaming_.store(false, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (allocator_) {
                // Unblocks GetBuffer() immediately before joining the worker thread
                allocator_->Decommit();
            }
        }
        if (thread_.joinable()) {
            thread_.join();
        }
        return S_OK;
    }

    void AirCastVcamPin::streamLoop() {
        timeBeginPeriod(1);
        aircast::ShmReader shm;
        std::vector<uint8_t> workBgra(aircast::kVcamFrameBytes, 0);
        std::vector<uint8_t> lastLiveBgra(aircast::kVcamFrameBytes, 0);

        bool hadLiveFrame = false;
        uint64_t lastLiveTick = 0;
        uint64_t frameIndex = 0;

        LARGE_INTEGER qpf{}, qpcStart{};
        QueryPerformanceFrequency(&qpf);
        QueryPerformanceCounter(&qpcStart);

        while (streaming_.load(std::memory_order_acquire)) {
            IMemAllocator* alloc = nullptr;
            IMemInputPin* memIn = nullptr;
            bool isYuy2 = true;
            LONG dstWidth = static_cast<LONG>(aircast::kVcamWidth);
            bool bottomUp = true;

            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (!allocator_ || !memInputPin_ || !hasConnectedMt_) break;
                alloc = allocator_;
                memIn = memInputPin_;
                alloc->AddRef();
                memIn->AddRef();

                isYuy2 = (connectedMt_.subtype == MEDIASUBTYPE_YUY2);
                if (connectedMt_.pbFormat) {
                    const auto* vih = reinterpret_cast<const VIDEOINFOHEADER*>(connectedMt_.pbFormat);
                    dstWidth = std::max(vih->bmiHeader.biWidth, static_cast<LONG>(aircast::kVcamWidth));
                    bottomUp = (vih->bmiHeader.biHeight > 0);
                }
            }

            IMediaSample* sample = nullptr;
            HRESULT hr = alloc->GetBuffer(&sample, nullptr, nullptr, 0);
            if (FAILED(hr) || !sample) {
                memIn->Release();
                alloc->Release();
                break;
            }

            // Respect dynamic stride/format changes from downstream renderers (EVR/Chrome)
            AM_MEDIA_TYPE* dynMt = nullptr;
            if (sample->GetMediaType(&dynMt) == S_OK && dynMt != nullptr) {
                if (isMediaTypeSupported(dynMt)) {
                    std::lock_guard<std::mutex> lock(mutex_);
                    clearMediaType(connectedMt_);
                    copyMediaType(&connectedMt_, dynMt);
                    isYuy2 = (connectedMt_.subtype == MEDIASUBTYPE_YUY2);
                    const auto* vih = reinterpret_cast<const VIDEOINFOHEADER*>(connectedMt_.pbFormat);
                    dstWidth = std::max(vih->bmiHeader.biWidth, static_cast<LONG>(aircast::kVcamWidth));
                    bottomUp = (vih->bmiHeader.biHeight > 0);
                }
                deleteMediaType(dynMt);
            }

            uint64_t shmSeq = 0;
            const bool gotLive = shm.readLatestBgra(workBgra.data(), shmSeq);
            const uint64_t nowTick = GetTickCount64();

            const uint8_t* srcBgra = nullptr;
            if (gotLive) {
                std::memcpy(lastLiveBgra.data(), workBgra.data(), aircast::kVcamFrameBytes);
                hadLiveFrame = true;
                lastLiveTick = nowTick;
                srcBgra = workBgra.data();
            } else if (hadLiveFrame && (nowTick - lastLiveTick) < 1000) {
                // Hold last frame for ~1s on disconnect so host apps don't flash
                srcBgra = lastLiveBgra.data();
            } else {
                renderStandbySlateBgra(workBgra.data(), frameIndex);
                srcBgra = workBgra.data();
            }

            BYTE* dstPtr = nullptr;
            if (SUCCEEDED(sample->GetPointer(&dstPtr)) && dstPtr != nullptr) {
                const long dstCap = sample->GetSize();
                if (isYuy2) {
                    const long needed = static_cast<long>(dstWidth) * static_cast<long>(aircast::kVcamHeight) * 2;
                    if (dstCap >= needed) {
                        convertBgraToYuy2(srcBgra, dstPtr, dstWidth);
                        sample->SetActualDataLength(needed);
                    }
                } else {
                    const long stride = ((dstWidth * 3) + 3) & ~3L;
                    const long needed = stride * static_cast<long>(aircast::kVcamHeight);
                    if (dstCap >= needed) {
                        convertBgraToRgb24(srcBgra, dstPtr, dstWidth, bottomUp);
                        sample->SetActualDataLength(needed);
                    }
                }

                REFERENCE_TIME tStart = static_cast<REFERENCE_TIME>(frameIndex) * kFrameInterval30Fps;
                REFERENCE_TIME tStop = tStart + kFrameInterval30Fps;
                sample->SetTime(&tStart, &tStop);
                sample->SetSyncPoint(TRUE);
                sample->SetDiscontinuity(frameIndex == 0 ? TRUE : FALSE);

                hr = memIn->Receive(sample);
            }

            sample->Release();
            memIn->Release();
            alloc->Release();

            if (FAILED(hr)) break;

            ++frameIndex;

            // Pace smoothly at 30.000 FPS using high-resolution QPC clock
            const double targetSec = static_cast<double>(frameIndex) / 30.0;
            LARGE_INTEGER qpcNow{};
            QueryPerformanceCounter(&qpcNow);
            const double elapsedSec = static_cast<double>(qpcNow.QuadPart - qpcStart.QuadPart) /
                                      static_cast<double>(qpf.QuadPart);
            const double remainMs = (targetSec - elapsedSec) * 1000.0;
            if (remainMs > 1.0) {
                Sleep(static_cast<DWORD>(remainMs));
            } else if (remainMs < -200.0) {
                // Re-anchor clock if host paused us
                QueryPerformanceCounter(&qpcStart);
                frameIndex = 0;
            }
        }

        shm.close();
        timeEndPeriod(1);
    }

// ---------------------------------------------------------------------------
// IClassFactory
// ---------------------------------------------------------------------------
    class AirCastClassFactory final : public IClassFactory {
    public:
        AirCastClassFactory() : ref_(1) { g_dllRefCount.fetch_add(1, std::memory_order_relaxed); }
        ~AirCastClassFactory() { g_dllRefCount.fetch_sub(1, std::memory_order_relaxed); }

        STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
            if (!ppv) return E_POINTER;
            if (riid == IID_IUnknown || riid == IID_IClassFactory) {
                *ppv = static_cast<IClassFactory*>(this);
                AddRef();
                return S_OK;
            }
            *ppv = nullptr;
            return E_NOINTERFACE;
        }
        STDMETHODIMP_(ULONG) AddRef() override { return ++ref_; }
        STDMETHODIMP_(ULONG) Release() override {
            const ULONG r = --ref_;
            if (r == 0) delete this;
            return r;
        }

        STDMETHODIMP CreateInstance(IUnknown* pUnkOuter, REFIID riid, void** ppv) override {
            if (!ppv) return E_POINTER;
            *ppv = nullptr;
            if (pUnkOuter != nullptr) return CLASS_E_NOAGGREGATION;
            auto* filter = new AirCastVcamFilter();
            const HRESULT hr = filter->QueryInterface(riid, ppv);
            filter->Release();
            return hr;
        }
        STDMETHODIMP LockServer(BOOL fLock) override {
            if (fLock) g_dllRefCount.fetch_add(1, std::memory_order_relaxed);
            else g_dllRefCount.fetch_sub(1, std::memory_order_relaxed);
            return S_OK;
        }

    private:
        std::atomic<ULONG> ref_;
    };

    HRESULT writeRegString(HKEY root, const wchar_t* subKey, const wchar_t* valueName, const wchar_t* data) {
        HKEY hKey = nullptr;
        const LONG rc = RegCreateKeyExW(root, subKey, 0, nullptr, REG_OPTION_NON_VOLATILE,
                                        KEY_WRITE, nullptr, &hKey, nullptr);
        if (rc != ERROR_SUCCESS) return HRESULT_FROM_WIN32(rc);
        const LONG wr = RegSetValueExW(hKey, valueName, 0, REG_SZ,
                                       reinterpret_cast<const BYTE*>(data),
                                       static_cast<DWORD>((std::wcslen(data) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
        return HRESULT_FROM_WIN32(wr);
    }

} // namespace

// ---------------------------------------------------------------------------
// Standard COM DLL Exports (invoked by Windows & regsvr32.exe)
// ---------------------------------------------------------------------------
BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID) {
if (reason == DLL_PROCESS_ATTACH) {
g_hModule = hModule;
DisableThreadLibraryCalls(hModule);
}
return TRUE;
}

STDAPI DllCanUnloadNow() {
    return (g_dllRefCount.load(std::memory_order_acquire) == 0) ? S_OK : S_FALSE;
}

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID* ppv) {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (rclsid != aircast::CLSID_AirCastVcam) return CLASS_E_CLASSNOTAVAILABLE;
    auto* factory = new AirCastClassFactory();
    const HRESULT hr = factory->QueryInterface(riid, ppv);
    factory->Release();
    return hr;
}

STDAPI DllRegisterServer() {
    wchar_t dllPath[MAX_PATH]{};
    if (GetModuleFileNameW(g_hModule, dllPath, MAX_PATH) == 0) {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    const std::wstring clsidKey = std::wstring(L"CLSID\\") + aircast::kVcamClsidStr;
    const std::wstring inprocKey = clsidKey + L"\\InprocServer32";

    HRESULT hr = writeRegString(HKEY_CLASSES_ROOT, clsidKey.c_str(), nullptr, aircast::kVcamFriendlyName);
    if (FAILED(hr)) return hr;
    hr = writeRegString(HKEY_CLASSES_ROOT, inprocKey.c_str(), nullptr, dllPath);
    if (FAILED(hr)) return hr;
    hr = writeRegString(HKEY_CLASSES_ROOT, inprocKey.c_str(), L"ThreadingModel", L"Both");
    if (FAILED(hr)) return hr;

    const HRESULT coHr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IFilterMapper2* mapper = nullptr;
    hr = CoCreateInstance(CLSID_FilterMapper2, nullptr, CLSCTX_INPROC_SERVER,
                          IID_IFilterMapper2, reinterpret_cast<void**>(&mapper));
    if (SUCCEEDED(hr) && mapper) {
        const REGPINTYPES pinTypes[2] = {
                {&MEDIATYPE_Video, &MEDIASUBTYPE_YUY2},
                {&MEDIATYPE_Video, &MEDIASUBTYPE_RGB24},
        };
        REGFILTERPINS2 pinReg{};
        pinReg.dwFlags = REG_PINFLAG_B_OUTPUT;
        pinReg.cInstances = 1;
        pinReg.nMediaTypes = 2;
        pinReg.lpMediaType = pinTypes;
        pinReg.clsPinCategory = &PIN_CATEGORY_CAPTURE;

        REGFILTER2 rf2{};
        rf2.dwVersion = 2;
        rf2.dwMerit = MERIT_DO_NOT_USE;
        rf2.cPins2 = 1;
        rf2.rgPins2 = &pinReg;

        IMoniker* moniker = nullptr;
        hr = mapper->RegisterFilter(
                aircast::CLSID_AirCastVcam,
                aircast::kVcamFriendlyName,
                &moniker,
                &CLSID_VideoInputDeviceCategory,
                aircast::kVcamFriendlyName,
                &rf2);
        if (moniker) moniker->Release();
        mapper->Release();
    }

    if (SUCCEEDED(coHr)) CoUninitialize();
    return hr;
}

STDAPI DllUnregisterServer() {
    const HRESULT coHr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IFilterMapper2* mapper = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_FilterMapper2, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_IFilterMapper2, reinterpret_cast<void**>(&mapper))) && mapper) {
        mapper->UnregisterFilter(&CLSID_VideoInputDeviceCategory,
                                 aircast::kVcamFriendlyName,
                                 aircast::CLSID_AirCastVcam);
        mapper->Release();
    }
    if (SUCCEEDED(coHr)) CoUninitialize();

    const std::wstring clsidKey = std::wstring(L"CLSID\\") + aircast::kVcamClsidStr;
    RegDeleteTreeW(HKEY_CLASSES_ROOT, clsidKey.c_str());
    return S_OK;
}