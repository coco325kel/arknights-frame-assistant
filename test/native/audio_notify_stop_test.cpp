#include "../../src/native/audio_notify.cpp"
#include <cstdio>

int main() {
    auto* bridge = new Bridge(nullptr, WM_APP);
    const HRESULT start = bridge->Start();
    if (FAILED(start)) {
        std::printf("FAIL: Start 0x%08lX\n", static_cast<unsigned long>(start));
        return 1;
    }
    bridge->AddRef();
    const HRESULT first = bridge->Stop();
    const HRESULT retry = bridge->Stop();
    bridge->Release();
    const HRESULT last = bridge->Stop();
    const HRESULT busy = HRESULT_FROM_WIN32(ERROR_BUSY);
    if (first != busy || retry != busy || FAILED(last)) {
        std::printf("FAIL: stop results 0x%08lX 0x%08lX 0x%08lX\n",
            static_cast<unsigned long>(first), static_cast<unsigned long>(retry), static_cast<unsigned long>(last));
        return 1;
    }
    bridge->Release();
    std::puts("PASS: Stop and retry retain held COM reference; release allows final Stop");
    return 0;
}
