@echo off
REM Build native paste helpers for KrakWhisper Windows
REM Requires Visual Studio Build Tools 2022

REM Try VS 2022 BuildTools first, then Community/Professional/Enterprise
if exist "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" (
    call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
) else if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" (
    call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
) else if exist "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat" (
    call "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
) else (
    echo ERROR: Visual Studio 2022 Build Tools not found.
    echo Install from: https://visualstudio.microsoft.com/visual-cpp-build-tools/
    exit /b 1
)

REM Ensure bin directory exists
if not exist "%~dp0\..\bin" mkdir "%~dp0\..\bin"

REM Build paste-helper.exe
echo Building paste-helper.exe...
cd /d "%~dp0\..\src"
cl.exe /EHsc /O2 /W3 paste-helper.cpp /link user32.lib /OUT:"..\bin\paste-helper.exe"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: paste-helper.exe build failed
    exit /b 1
)
echo   OK: bin\paste-helper.exe

REM Build get-foreground.exe
echo Building get-foreground.exe...
cl.exe /EHsc /O2 /W3 get-foreground.cpp /link user32.lib /OUT:"..\bin\get-foreground.exe"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: get-foreground.exe build failed
    exit /b 1
)
echo   OK: bin\get-foreground.exe

echo.
echo Build complete! Helpers are in electron\bin\
