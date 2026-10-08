#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <mmdeviceapi.h>
#include <audiopolicy.h>
#include <wrl/client.h>
#include <atomic>
#include <memory>
#include <string>
#include <thread>
#include <vector>
#include <algorithm>

using Microsoft::WRL::ComPtr;

// Message payloads contain integers only. All audio interfaces stay in this MTA.
enum EventKind { DeviceChanged = 1, SessionCreated = 2, Ready = 3, Degraded = 4, Recovered = 5 };

class Bridge final : public IMMNotificationClient, public IAudioSessionNotification {
public:
    Bridge(HWND window, UINT message) : window_(window), message_(message) {
        stop_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        changed_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        ready_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        stopReply_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        targets_ = std::make_shared<const std::vector<DWORD>>();
    }
    ~Bridge() {
        if (stop_) CloseHandle(stop_);
        if (changed_) CloseHandle(changed_);
        if (ready_) CloseHandle(ready_);
        if (stopReply_) CloseHandle(stopReply_);
    }
    HRESULT Start() {
        if (!stop_ || !changed_ || !ready_ || !stopReply_) return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_MEMORY);
        worker_ = std::thread([this] { Run(); });
        WaitForSingleObject(ready_, INFINITE);
        return startup_.load();
    }
    HRESULT Stop() {
        stopping_.store(true);
        if (!worker_.joinable())
            return refs_.load() == 1 ? S_OK : HRESULT_FROM_WIN32(ERROR_BUSY);
        ResetEvent(stopReply_);
        if (!exited_.load()) {
            SetEvent(stop_);
            WaitForSingleObject(stopReply_, INFINITE);
        }
        // Endpoint registration does not AddRef. Its explicit cleanup result is required.
        const HRESULT cleanup = cleanup_.load();
        if (FAILED(cleanup)) return cleanup;
        worker_.join();
        return refs_.load() == 1 ? S_OK : HRESULT_FROM_WIN32(ERROR_BUSY);
    }
    void Update(const DWORD* pids, UINT count) {
        auto next = std::make_shared<std::vector<DWORD>>();
        if (count) next->assign(pids, pids + count);
        std::shared_ptr<const std::vector<DWORD>> immutable = next;
        std::atomic_store(&targets_, immutable);
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IMMNotificationClient))
            *out = static_cast<IMMNotificationClient*>(this);
        else if (iid == __uuidof(IAudioSessionNotification))
            *out = static_cast<IAudioSessionNotification*>(this);
        else return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = --refs_;
        if (!remaining) delete this;
        return remaining;
    }
    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { Changed(); return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { Changed(); return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { Changed(); return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole, LPCWSTR) override {
        if (flow == eRender || flow == eAll) Changed();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override {
        Changed();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnSessionCreated(IAudioSessionControl* session) override {
        if (stopping_.load()) return S_OK;
        ComPtr<IAudioSessionControl2> control;
        DWORD pid = 0;
        if (session && SUCCEEDED(session->QueryInterface(IID_PPV_ARGS(&control))) &&
            SUCCEEDED(control->GetProcessId(&pid))) {
            const auto targets = std::atomic_load(&targets_);
            if (std::find(targets->begin(), targets->end(), pid) == targets->end()) return S_OK;
        }
        Post(SessionCreated, pid);
        return S_OK;
    }
private:
    struct Watch {
        std::wstring id;
        ComPtr<IAudioSessionManager2> manager;
    };
    void Post(EventKind kind, LPARAM value = 0) noexcept {
        if (!stopping_.load()) PostMessageW(window_, message_, kind, value);
    }
    void Changed() noexcept {
        if (stopping_.load()) return;
        // Callbacks never register/unregister or release the last manager reference.
        forceRebind_.store(true);
        SetEvent(changed_);
        Post(DeviceChanged);
    }
    static HRESULT Health(IAudioSessionManager2* manager) {
        ComPtr<IAudioSessionEnumerator> sessions;
        int count = 0;
        HRESULT hr = manager->GetSessionEnumerator(&sessions);
        return FAILED(hr) ? hr : sessions->GetCount(&count);
    }
    HRESULT Rebuild(IMMDeviceEnumerator* enumerator, std::vector<Watch>& watches, bool force) {
        ComPtr<IMMDeviceCollection> devices;
        HRESULT hr = enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &devices);
        if (FAILED(hr)) return hr;
        UINT count = 0;
        if (FAILED(hr = devices->GetCount(&count))) return hr;
        std::vector<std::wstring> active;
        active.reserve(count);
        watches.reserve(watches.size() + count);
        HRESULT failure = S_OK;
        for (UINT i = 0; i < count; ++i) {
            ComPtr<IMMDevice> device;
            LPWSTR rawId = nullptr;
            if (FAILED(hr = devices->Item(i, &device)) || FAILED(hr = device->GetId(&rawId))) {
                failure = hr;
                continue;
            }
            std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> ownedId(rawId, CoTaskMemFree);
            std::wstring id(rawId);
            active.push_back(id);
            const auto old = std::find_if(watches.begin(), watches.end(), [&](const Watch& w) { return w.id == id; });
            if (old != watches.end()) {
                if (!force && SUCCEEDED(Health(old->manager.Get()))) continue;
                hr = old->manager->UnregisterSessionNotification(this);
                if (FAILED(hr)) { failure = hr; continue; }
                watches.erase(old);
            }
            ComPtr<IAudioSessionManager2> manager;
            if (FAILED(hr = device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, &manager))) {
                failure = hr;
                continue;
            }
            if (FAILED(hr = manager->RegisterSessionNotification(this))) { failure = hr; continue; }
            // Keep the registration owned even if its initial enumeration fails.
            watches.push_back({std::move(id), manager});
            // GetCount is required to enable session-created notifications, AFTER registering.
            hr = Health(manager.Get());
            if (FAILED(hr)) failure = hr;
            else Post(Ready); // Also rescan sessions discovered during a repaired subscription's gap.
        }
        for (auto it = watches.begin(); it != watches.end();) {
            if (std::find(active.begin(), active.end(), it->id) == active.end()) {
                hr = it->manager->UnregisterSessionNotification(this);
                if (FAILED(hr)) { failure = hr; ++it; }
                else it = watches.erase(it);
            } else ++it;
        }
        return failure;
    }
    HRESULT Cleanup(IMMDeviceEnumerator* enumerator, std::vector<Watch>& watches, bool& registered) {
        HRESULT failure = S_OK;
        for (auto it = watches.begin(); it != watches.end();) {
            const HRESULT hr = it->manager->UnregisterSessionNotification(this);
            if (FAILED(hr)) { failure = hr; ++it; }
            else it = watches.erase(it);
        }
        if (registered) {
            const HRESULT hr = enumerator->UnregisterEndpointNotificationCallback(this);
            if (FAILED(hr)) failure = hr;
            else registered = false;
        }
        return failure;
    }
    void Run() noexcept {
        const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(com)) {
            startup_.store(com); cleanup_.store(S_OK); exited_.store(true);
            SetEvent(ready_); SetEvent(stopReply_); return;
        }
        ComPtr<IMMDeviceEnumerator> enumerator;
        std::vector<Watch> watches;
        bool registered = false, signalled = false;
        try {
            HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
            if (SUCCEEDED(hr)) hr = enumerator->RegisterEndpointNotificationCallback(this);
            registered = SUCCEEDED(hr);
            startup_.store(hr);
            SetEvent(ready_);
            signalled = true;
            if (registered) {
                bool healthy = true, first = true;
                const HANDLE events[] = {stop_, changed_};
                do {
                    const bool force = forceRebind_.exchange(false) || first;
                    hr = Rebuild(enumerator.Get(), watches, force);
                    if (FAILED(hr)) Post(Degraded, hr);
                    else if (!healthy) Post(Recovered);
                    else if (first || force) Post(Ready);
                    first = false;
                    healthy = SUCCEEDED(hr);
                    // A stale manager can stop sending callbacks. Probe it even without an event.
                    const DWORD wait = WaitForMultipleObjects(2, events, FALSE, 5000);
                    if (wait == WAIT_OBJECT_0) break;
                    if (wait != WAIT_OBJECT_0 + 1 && wait != WAIT_TIMEOUT) { Post(Degraded, E_FAIL); break; }
                } while (!stopping_.load());
            }
        } catch (...) {
            if (!signalled) { startup_.store(E_OUTOFMEMORY); SetEvent(ready_); }
            Post(Degraded, E_OUTOFMEMORY);
        }
        // If unregistration fails, retain both the MTA and its interfaces; the caller
        // receives a failure and must keep the DLL loaded. Retry on the next stop or 5s.
        while (true) {
            const HRESULT hr = Cleanup(enumerator.Get(), watches, registered);
            cleanup_.store(hr);
            if (SUCCEEDED(hr)) break;
            SetEvent(stopReply_);
            WaitForSingleObject(stop_, 5000);
        }
        enumerator.Reset();
        CoUninitialize();
        exited_.store(true);
        SetEvent(stopReply_);
    }
    std::atomic<ULONG> refs_{1};
    std::atomic<bool> stopping_{false};
    std::atomic<bool> exited_{false};
    std::atomic<bool> forceRebind_{false};
    HWND window_;
    UINT message_;
    HANDLE stop_ = nullptr, changed_ = nullptr, ready_ = nullptr, stopReply_ = nullptr;
    std::thread worker_;
    std::atomic<HRESULT> startup_{E_PENDING}, cleanup_{E_PENDING};
    std::shared_ptr<const std::vector<DWORD>> targets_;
};

extern "C" __declspec(dllexport) HRESULT WINAPI AfaAudioStart(HWND window, UINT message, Bridge** out) {
    if (!out || !IsWindow(window) || message < WM_APP || message > 0xFFFF) return E_INVALIDARG;
    *out = nullptr;
    try {
        Bridge* bridge = new Bridge(window, message);
        *out = bridge;
        // A non-null handle must be stopped even if startup fails.
        return bridge->Start();
    } catch (...) {
        return E_OUTOFMEMORY;
    }
}
extern "C" __declspec(dllexport) HRESULT WINAPI AfaAudioUpdateTargets(Bridge* bridge, const DWORD* pids, UINT count) {
    if (!bridge || (count && !pids) || count > 65536) return E_INVALIDARG;
    try { bridge->Update(pids, count); return S_OK; } catch (...) { return E_OUTOFMEMORY; }
}
extern "C" __declspec(dllexport) HRESULT WINAPI AfaAudioStop(Bridge* bridge) {
    if (!bridge) return E_INVALIDARG;
    const HRESULT hr = bridge->Stop();
    if (SUCCEEDED(hr)) bridge->Release();
    return hr;
}
