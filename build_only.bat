@echo off
echo.
echo ========================================
echo   MimiClaw Auto-Build
echo ========================================
echo.

REM Auto-detect local IP address
echo [0/1] Detecting local IP address...
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /C:"IPv4 Address" ^| findstr "192.168"') do (
    set IP=%%a
    goto :ip_found
)
:ip_found
set IP=%IP:~1%
echo Detected IP: %IP%

REM Update mimi_secrets.h with current IP
echo Updating server IP in mimi_secrets.h...
powershell -Command "(Get-Content 'main\mimi_secrets.h') -replace 'MIMI_SECRET_STT_HOST\s+\"[0-9.]+\"', 'MIMI_SECRET_STT_HOST        \"%IP%\"' | Set-Content 'main\mimi_secrets.h'"
powershell -Command "(Get-Content 'main\mimi_secrets.h') -replace 'http://[0-9.]+:4000', 'http://%IP%:4000' | Set-Content 'main\mimi_secrets.h'"
echo IP configuration updated to: %IP%
echo.

set "MSYSTEM="
set "MSYS="
set "IDF_PATH=C:\esp\v5.5.2\esp-idf"
set "IDF_TOOLS_PATH=C:\Espressif"
set "IDF_CCACHE_ENABLE=0"
set "PATH=C:\Espressif\python_env\idf5.5_py3.11_env\Scripts;%PATH%"
set "PATH=C:\Espressif\tools\idf-git\2.44.0\cmd;%PATH%"
cd /d "C:\Projects\embedded\mimiclaw"
call "%IDF_PATH%\export.bat" >nul 2>&1

REM Full clean when sdkconfig.defaults is newer than sdkconfig (or sdkconfig missing)
set NEEDS_CLEAN=0
if not exist sdkconfig set NEEDS_CLEAN=1
if exist sdkconfig (
    for /f %%A in ('powershell -Command "if ((Get-Item sdkconfig.defaults.esp32s3).LastWriteTime -gt (Get-Item sdkconfig).LastWriteTime) { echo 1 } else { echo 0 }"') do set NEEDS_CLEAN=%%A
)
if "%NEEDS_CLEAN%"=="1" (
    echo [CLEAN] sdkconfig.defaults changed - running fullclean...
    if exist sdkconfig del /f sdkconfig
    if exist build rmdir /s /q build
    echo [CLEAN] Setting target esp32s3...
    python "%IDF_PATH%\tools\idf.py" set-target esp32s3 2>&1
    echo [CLEAN] Done.
    echo.
)

python "%IDF_PATH%\tools\idf.py" build 2>&1
