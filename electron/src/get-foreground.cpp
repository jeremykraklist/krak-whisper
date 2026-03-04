/**
 * get-foreground.exe — Print the HWND of the current foreground window.
 *
 * Usage: get-foreground.exe
 * Output: decimal HWND value on stdout
 *
 * Compile: cl.exe /EHsc /O2 get-foreground.cpp /link user32.lib /OUT:get-foreground.exe
 */

#include <windows.h>
#include <cstdio>

int main() {
    HWND hwnd = GetForegroundWindow();
    printf("%lld\n", (long long)(intptr_t)hwnd);
    return 0;
}
