@echo off
setlocal enabledelayedexpansion
rem usage: build test\hello   ->  bin\hello.exe

if "%~1"=="" (echo usage: build path\name & exit /b 1)
set SRC=%~dpn1.asm
set NAME=%~n1
pushd "%~dp0"

set NASM=%LOCALAPPDATA%\bin\NASM\nasm.exe
set SDKLIB=%ProgramFiles(x86)%\Windows Kits\10\Lib\10.0.26100.0\um\x64
rem not LINK - link.exe reads %LINK% as extra command line options
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -find VC\Tools\MSVC\**\bin\Hostx64\x64\link.exe`) do set LINKER=%%i

if not exist build\lib mkdir build\lib
if not exist bin mkdir bin
set ASM="%NASM%" -f win64 -g -F cv8 -I lib/

rem every program gets all of lib\ linked in, it's small
set OBJS=
for %%f in (lib\*.asm) do (
    %ASM% -o build\lib\%%~nf.obj %%f || goto fail
    set OBJS=!OBJS! build\lib\%%~nf.obj
)

%ASM% -o build\%NAME%.obj "%SRC%" || goto fail
"%LINKER%" /nologo /subsystem:console /entry:start /nodefaultlib /debug /incremental:no ^
    /out:bin\%NAME%.exe build\%NAME%.obj %OBJS% kernel32.lib /libpath:"%SDKLIB%" || goto fail

echo built bin\%NAME%.exe
popd
exit /b 0

:fail
popd
exit /b 1
