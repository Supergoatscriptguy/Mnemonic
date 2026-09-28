@echo off
setlocal
rem usage: build test\hello   ->  bin\hello.exe

if "%~1"=="" (echo usage: build path\name & exit /b 1)
set SRC=%~dpn1.asm
set NAME=%~n1
pushd "%~dp0"

set NASM=%LOCALAPPDATA%\bin\NASM\nasm.exe
set SDKLIB=%ProgramFiles(x86)%\Windows Kits\10\Lib\10.0.26100.0\um\x64
rem not LINK - link.exe reads %LINK% as extra command line options
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -find VC\Tools\MSVC\**\bin\Hostx64\x64\link.exe`) do set LINKER=%%i

if not exist build mkdir build
if not exist bin mkdir bin

"%NASM%" -f win64 -g -F cv8 -o build\%NAME%.obj "%SRC%" || goto fail
"%LINKER%" /nologo /subsystem:console /entry:start /nodefaultlib /debug /incremental:no ^
    /out:bin\%NAME%.exe build\%NAME%.obj kernel32.lib /libpath:"%SDKLIB%" || goto fail

echo built bin\%NAME%.exe
popd
exit /b 0

:fail
popd
exit /b 1
