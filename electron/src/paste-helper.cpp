/**
 * paste-helper.exe — Native Win32 paste helper for KrakWhisper
 *
 * Usage: paste-helper.exe <hwnd_decimal> <text_to_paste>
 *
 * 1. Optionally restores focus to the target window (if hwnd != 0)
 * 2. Writes text to the clipboard as CF_UNICODETEXT
 * 3. Simulates Ctrl+V via SendInput
 *
 * Returns 0 on success, 1 on failure.
 * Errors are printed to stderr.
 *
 * Compile: cl.exe /EHsc /O2 paste-helper.cpp /link user32.lib /OUT:paste-helper.exe
 */

#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

/**
 * Convert a narrow (UTF-8 / ANSI) string to a wide string.
 * Caller must free() the result.
 */
static wchar_t* toWide(const char* narrow) {
    int len = MultiByteToWideChar(CP_UTF8, 0, narrow, -1, nullptr, 0);
    if (len <= 0) return nullptr;
    wchar_t* wide = (wchar_t*)malloc(len * sizeof(wchar_t));
    if (!wide) return nullptr;
    MultiByteToWideChar(CP_UTF8, 0, narrow, -1, wide, len);
    return wide;
}

/**
 * Restore focus to the target window identified by hwnd.
 * Uses AttachThreadInput to steal foreground permission.
 */
static bool restoreFocus(HWND hwnd) {
    if (!hwnd || !IsWindow(hwnd)) return false;

    DWORD targetThread = GetWindowThreadProcessId(hwnd, nullptr);
    DWORD ourThread = GetCurrentThreadId();
    bool attached = false;

    if (targetThread != ourThread) {
        attached = AttachThreadInput(ourThread, targetThread, TRUE) != 0;
    }

    AllowSetForegroundWindow(ASFW_ANY);
    SetForegroundWindow(hwnd);

    // Brief wait for the window manager to process focus change
    Sleep(10);

    if (attached) {
        AttachThreadInput(ourThread, targetThread, FALSE);
    }

    return true;
}

/**
 * Write Unicode text to the system clipboard.
 */
static bool writeClipboard(const wchar_t* text) {
    if (!OpenClipboard(nullptr)) {
        fprintf(stderr, "Error: OpenClipboard failed (err=%lu)\n", GetLastError());
        return false;
    }

    EmptyClipboard();

    size_t len = wcslen(text);
    size_t bytes = (len + 1) * sizeof(wchar_t);
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!hMem) {
        fprintf(stderr, "Error: GlobalAlloc failed\n");
        CloseClipboard();
        return false;
    }

    wchar_t* dest = (wchar_t*)GlobalLock(hMem);
    if (!dest) {
        fprintf(stderr, "Error: GlobalLock failed\n");
        GlobalFree(hMem);
        CloseClipboard();
        return false;
    }

    memcpy(dest, text, bytes);
    GlobalUnlock(hMem);

    if (!SetClipboardData(CF_UNICODETEXT, hMem)) {
        fprintf(stderr, "Error: SetClipboardData failed (err=%lu)\n", GetLastError());
        GlobalFree(hMem);
        CloseClipboard();
        return false;
    }

    CloseClipboard();
    return true;
}

/**
 * Simulate Ctrl+V using SendInput (preferred over keybd_event).
 */
static bool simulateCtrlV() {
    INPUT inputs[4] = {};

    // Key down: Ctrl
    inputs[0].type = INPUT_KEYBOARD;
    inputs[0].ki.wVk = VK_CONTROL;

    // Key down: V
    inputs[1].type = INPUT_KEYBOARD;
    inputs[1].ki.wVk = 0x56; // V

    // Key up: V
    inputs[2].type = INPUT_KEYBOARD;
    inputs[2].ki.wVk = 0x56;
    inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;

    // Key up: Ctrl
    inputs[3].type = INPUT_KEYBOARD;
    inputs[3].ki.wVk = VK_CONTROL;
    inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;

    UINT sent = SendInput(4, inputs, sizeof(INPUT));
    if (sent != 4) {
        fprintf(stderr, "Error: SendInput sent %u of 4 events (err=%lu)\n", sent, GetLastError());
        return false;
    }

    return true;
}

int main(int argc, char* argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: paste-helper.exe <hwnd_decimal> <text_to_paste>\n");
        return 1;
    }

    // Parse HWND from decimal string
    long long hwndVal = _atoi64(argv[1]);
    HWND targetHwnd = (HWND)(intptr_t)hwndVal;

    // Convert text to wide string
    const char* textUtf8 = argv[2];
    wchar_t* textWide = toWide(textUtf8);
    if (!textWide) {
        fprintf(stderr, "Error: Failed to convert text to Unicode\n");
        return 1;
    }

    // Step 1: Restore focus to target window (if valid)
    if (targetHwnd && IsWindow(targetHwnd)) {
        restoreFocus(targetHwnd);
    }

    // Step 2: Write text to clipboard
    if (!writeClipboard(textWide)) {
        free(textWide);
        return 1;
    }
    free(textWide);

    // Step 3: Wait for clipboard to settle
    Sleep(20);

    // Step 4: Simulate Ctrl+V
    if (!simulateCtrlV()) {
        return 1;
    }

    return 0;
}
