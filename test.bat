@echo off
setlocal
rem builds every test program and every tool, then runs the self-checking tests
pushd "%~dp0"
set BAD=0

for %%t in (hello cpuinfo fmt sys rng threads progress ctrltest data tok gpu mx grad model infer asmdata) do (
    call .\build.bat test\%%t >nul || (echo build failed: %%t& set BAD=1)
)
rem the tools too, so nothing rots unnoticed
for %%t in (pqinfo pqcat extract docsinfo download chatdocs) do (
    call .\build.bat data\%%t >nul || (echo build failed: %%t& set BAD=1)
)
for %%t in (bpetrain tokenize tokshow) do (
    call .\build.bat tokenizer\%%t >nul || (echo build failed: %%t& set BAD=1)
)
for %%t in (gpuinfo gpubench) do (
    call .\build.bat gpu\%%t >nul || (echo build failed: %%t& set BAD=1)
)
call .\build.bat train\train >nul || (echo build failed: train& set BAD=1)
call .\build.bat train\chatpack >nul || (echo build failed: chatpack& set BAD=1)
call .\build.bat train\profile >nul || (echo build failed: profile& set BAD=1)
call .\build.bat asmdata\asmset >nul || (echo build failed: asmset& set BAD=1)
call .\build.bat asmdata\nasmeval >nul || (echo build failed: nasmeval& set BAD=1)
call .\build.bat test\resume >nul || (echo build failed: resume& set BAD=1)
for %%t in (quantize chat gguf) do (
    call .\build.bat chat\%%t >nul || (echo build failed: %%t& set BAD=1)
)
call .\build.bat site\engine >nul || (echo build failed: engine.wasm& set BAD=1)
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
echo == tokenizer
bin\tok.exe || set BAD=1
echo == gpu
bin\gpu.exe || set BAD=1
echo == mxfp8
bin\mx.exe || set BAD=1
echo == gradients
bin\grad.exe || set BAD=1
echo == fast kernels vs naive
bin\model.exe || set BAD=1
echo == stop and resume training
bin\resume.exe || set BAD=1
echo == cpu inference
bin\infer.exe || set BAD=1
echo == nasm lesson tools (builds and runs candidates)
bin\asmdata.exe || set BAD=1
echo == the webassembly engine vs bin\chat
node site\test.mjs threads=12 || set BAD=1

:done
echo.
if %BAD%==1 (echo SOME TESTS FAILED) else (echo all tests passed)
popd
exit /b %BAD%
