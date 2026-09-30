@echo off
setlocal
rem mkollama checkpoint tag ctx [name]      e.g. mkollama checkpoints\chatid\step_00000306.ckpt 126m 1024
rem bin\gguf turns the checkpoint into models\mnemonic-<tag>-{q8_0,q4_0,f16}.gguf, then these
rem become the ollama models <name>:<tag> (q8_0), <name>:<tag>-q4_0 and <name>:<tag>-f16.
rem name defaults to mnemonic. chat\Modelfile has the chat template and the sampling settings
pushd "%~dp0"
if "%~3"=="" (echo usage: mkollama checkpoint tag ctx [name]& popd& exit /b 1)
set NAME=%~4
if "%NAME%"=="" set NAME=mnemonic
call :one "%~1" %2 %3 q8_0 %NAME%:%2 || goto fail
call :one "%~1" %2 %3 q4_0 %NAME%:%2-q4_0 || goto fail
call :one "%~1" %2 %3 f16 %NAME%:%2-f16 || goto fail
popd
exit /b 0

:one
bin\gguf.exe %1 models\mnemonic-%2-%4.gguf %4 || exit /b 1
> models\Modelfile.tmp echo FROM %CD%\models\mnemonic-%2-%4.gguf
>> models\Modelfile.tmp echo PARAMETER num_ctx %3
type chat\Modelfile >> models\Modelfile.tmp
ollama create %5 -f models\Modelfile.tmp || exit /b 1
del models\Modelfile.tmp
exit /b 0

:fail
echo failed
popd
exit /b 1
