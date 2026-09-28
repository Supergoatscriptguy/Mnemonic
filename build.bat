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
if not exist build\mod mkdir build\mod
if not exist bin mkdir bin
set ASM="%NASM%" -f win64 -g -F cv8 -I lib/

rem every program gets all of lib\ linked in, it's small
set OBJS=
for %%f in (lib\*.asm) do (
    %ASM% -o build\lib\%%~nf.obj %%f || goto fail
    set OBJS=!OBJS! build\lib\%%~nf.obj
)

rem anything else it needs is listed in the source:
rem   ; uses: data\parquet data\zstd      (modules)
rem   ; libs: winhttp.lib                 (extra import libs)
set USES=
set LIBS=
for /f "eol=# tokens=1,* delims=:" %%a in ('findstr /b /c:"; uses:" "%SRC%"') do set USES=%%b
for /f "eol=# tokens=1,* delims=:" %%a in ('findstr /b /c:"; libs:" "%SRC%"') do set LIBS=%%b
rem module objects are named after their whole path, test\tok and tokenizer\tok can't collide
for %%m in (%USES%) do (
    set MOD=%%m
    set MOD=!MOD:\=_!
    %ASM% -o build\mod\!MOD!.obj %%m.asm || goto fail
    set OBJS=!OBJS! build\mod\!MOD!.obj
)

%ASM% -o build\%NAME%.obj "%SRC%" || goto fail
"%LINKER%" /nologo /subsystem:console /entry:start /nodefaultlib /debug /incremental:no /map ^
    /out:bin\%NAME%.exe build\%NAME%.obj %OBJS% kernel32.lib %LIBS% /libpath:"%SDKLIB%" || goto fail

echo built bin\%NAME%.exe
popd
exit /b 0

:fail
popd
exit /b 1
