@echo off
setlocal enabledelayedexpansion

REM release.sh fills in DEFAULT_SERVER_URL on the copy it ships.
set DEFAULT_SERVER_URL=
if defined WW_UPDATE_SERVER (
    set SERVER_URL=%WW_UPDATE_SERVER%
) else (
    set SERVER_URL=%DEFAULT_SERVER_URL%
)
if "%SERVER_URL%"=="" (
    echo No server set. Run: set WW_UPDATE_SERVER=http://host:8080 and then launcher.bat
    pause
    exit /b 1
)

set INSTALL_DIR=%~dp0WizardWars
set VERSION_FILE=%INSTALL_DIR%\version.txt
set TEMP_ZIP=%TEMP%\WizardWars-windows.zip
set TEMP_VER=%TEMP%\ww_version.txt

echo WizardWars Launcher
echo ===================
echo Server: %SERVER_URL%
echo.

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

REM Check remote version
curl -sf "%SERVER_URL%/version.txt" -o "%TEMP_VER%" 2>nul
if errorlevel 1 (
    echo Warning: Cannot reach update server. Launching cached version.
    goto :launch
)

set /p REMOTE_VERSION=<"%TEMP_VER%"
del "%TEMP_VER%" 2>nul

set LOCAL_VERSION=
if exist "%VERSION_FILE%" set /p LOCAL_VERSION=<"%VERSION_FILE%"

if "%REMOTE_VERSION%"=="%LOCAL_VERSION%" (
    echo Up to date ^(%LOCAL_VERSION%^)
    goto :patch
)

echo Update available: %LOCAL_VERSION% -^> %REMOTE_VERSION%
echo Downloading...

curl -f --progress-bar -o "%TEMP_ZIP%" "%SERVER_URL%/WizardWars-windows.zip"
if errorlevel 1 (
    echo Error: Download failed.
    pause
    exit /b 1
)

echo Extracting...
if exist "%INSTALL_DIR%\WizardWars.exe" del /q "%INSTALL_DIR%\WizardWars.exe"
powershell -NoProfile -Command "Expand-Archive -Force -Path \"%TEMP_ZIP%\" -DestinationPath \"%INSTALL_DIR%\""
del /q "%TEMP_ZIP%" 2>nul

echo %REMOTE_VERSION%>"%VERSION_FILE%"
echo Updated to %REMOTE_VERSION%!
echo.

:patch
REM Legacy: releases used to be patchable with a small patch.pck dropped next to the
REM exe. That is gone — clear one an older launcher may have installed.
if exist "%INSTALL_DIR%\patch.pck" del /q "%INSTALL_DIR%\patch.pck"
if exist "%INSTALL_DIR%\patch.txt" del /q "%INSTALL_DIR%\patch.txt"

:launch
if not exist "%INSTALL_DIR%\WizardWars.exe" (
    echo Error: WizardWars.exe not found. Download may have failed.
    pause
    exit /b 1
)

echo Launching WizardWars...
start "" "%INSTALL_DIR%\WizardWars.exe"
