@echo off
setlocal
rem builds every test program and runs the self-checking ones
pushd "%~dp0"
set BAD=0

for %%t in (hello cpuinfo fmt sys rng threads progress ctrltest data) do (
    call .\build.bat test\%%t >nul || (echo build failed: %%t& set BAD=1)
)
rem the tools too, so nothing rots unnoticed
for %%t in (pqinfo pqcat extract docsinfo download) do (
    call .\build.bat data\%%t >nul || (echo build failed: %%t& set BAD=1)
)
if %BAD%==1 goto done

bin\cpuinfo.exe
echo.
echo == fmt
bin\fmt.exe || set BAD=1
echo == sys
bin\sys.exe lr=1e-3 foo="a b" || set BAD=1
echo == rng
bin\rng.exe || set BAD=1
echo == threads
bin\threads.exe || set BAD=1
echo == ctrl+c
bin\ctrltest.exe || set BAD=1
echo == data
bin\data.exe || set BAD=1

:done
echo.
if %BAD%==1 (echo SOME TESTS FAILED) else (echo all tests passed)
popd
exit /b %BAD%
