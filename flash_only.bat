@echo off
set "MSYSTEM="
set "MSYS="
set "IDF_PATH=C:\esp\v5.5.2\esp-idf"
set "IDF_TOOLS_PATH=C:\Espressif"
set "IDF_CCACHE_ENABLE=0"
set "PATH=C:\Espressif\python_env\idf5.5_py3.11_env\Scripts;%PATH%"
set "PATH=C:\Espressif\tools\idf-git\2.44.0\cmd;%PATH%"
cd /d "C:\Projects\embedded\mimiclaw"
call "%IDF_PATH%\export.bat" >nul 2>&1
python "%IDF_PATH%\tools\idf.py" -p COM31 flash 2>&1
