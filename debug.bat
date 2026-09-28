@echo off
rem usage: debug hello   ->  opens bin\hello.exe in x64dbg
set DBG=%LOCALAPPDATA%\Microsoft\WinGet\Packages\x64dbg.x64dbg_Microsoft.Winget.Source_8wekyb3d8bbwe\release\x64\x64dbg.exe
if not exist "%DBG%" (echo x64dbg not found at %DBG% & exit /b 1)
start "" "%DBG%" "%~dp0bin\%~n1.exe"
