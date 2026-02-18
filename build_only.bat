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
python "%IDF_PATH%\tools\idf.py" build 2>&1
