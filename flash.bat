@echo off
REM Fixed Flash Script - Disables ccache to prevent compiler crashes

echo.
echo ========================================
echo   MimiClaw Auto-Flash (ccache disabled)
echo ========================================
echo.

REM Auto-detect local IP address
echo [0/4] Detecting local IP address...
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

REM Set ESP-IDF paths
set "IDF_PATH=C:\esp\v5.5.2\esp-idf"
set "IDF_TOOLS_PATH=C:\Espressif"
set "PATH=C:\Espressif\python_env\idf5.5_py3.11_env\Scripts;%PATH%"
set "PATH=C:\Espressif\tools\idf-git\2.44.0\cmd;%PATH%"

REM Disable ccache to prevent compiler crashes
set "IDF_CCACHE_ENABLE=0"

cd /d "C:\Projects\embedded\mimiclaw"

echo Current directory: %CD%
echo ESP-IDF Path: %IDF_PATH%
echo CCache: DISABLED (prevents compiler crashes)
echo.

REM Initialize ESP-IDF environment
echo Initializing ESP-IDF environment...
call "%IDF_PATH%\export.bat"

echo.
echo [1/4] Setting target to ESP32-S3...
python "%IDF_PATH%\tools\idf.py" set-target esp32s3

echo.
echo [2/4] Clean reconfigure...
python "%IDF_PATH%\tools\idf.py" fullclean reconfigure

echo.
echo [3/4] Building (3-6 minutes without ccache)...
python "%IDF_PATH%\tools\idf.py" build

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ========================================
    echo   BUILD FAILED!
    echo ========================================
    pause
    exit /b 1
)

echo.
echo ========================================
echo   BUILD SUCCESS!
echo ========================================
echo.

echo [4/4] Flashing to COM31...
python "%IDF_PATH%\tools\idf.py" -p COM31 flash monitor

pause
