@echo off
setlocal
set "FW_DIR=%~dp0"
set "ML_EXE="
set "LINK_EXE="

if exist "C:\masm32\bin\ml.exe" (
    set "MASM_BIN=C:\masm32\bin"
    set "ML_EXE=C:\masm32\bin\ml.exe"
    set "LINK_EXE=C:\masm32\bin\link16.exe"
) else (
    for %%I in (ml.exe) do set "ML_EXE=%%~$PATH:I"
    for %%I in (link16.exe) do set "LINK_EXE=%%~$PATH:I"
)

if "%ML_EXE%"=="" (
    echo ERROR: ml.exe not found in C:\masm32\bin or PATH.
    exit /b 1
)
if "%LINK_EXE%"=="" (
    echo ERROR: link16.exe not found in C:\masm32\bin or PATH.
    exit /b 1
)

if defined MASM_BIN set "PATH=%MASM_BIN%;%PATH%"
if not exist "%FW_DIR%Debug" mkdir "%FW_DIR%Debug"
pushd "%FW_DIR%Debug" || exit /b 1

"%ML_EXE%" /c /Zd /Zi ..\main.asm
if errorlevel 1 (
    echo ERROR: Assembly failed.
    popd
    exit /b 1
)

"%LINK_EXE%" /CODEVIEW main,Debug.exe,nul.map,,,
if errorlevel 1 (
    echo ERROR: Linking failed.
    popd
    exit /b 1
)

popd
echo Build succeeded: "%FW_DIR%Debug\Debug.exe"
exit /b 0
