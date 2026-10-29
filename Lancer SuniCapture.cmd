@echo off
setlocal
set "SUNICAPTURE_EXE=%~dp0dist\SuniCapture-0.4.0-win-x64\SuniCapture.exe"
if exist "%SUNICAPTURE_EXE%" (
    start "" "%SUNICAPTURE_EXE%"
    exit /b 0
)
echo Compilez d'abord l'application avec :
echo powershell -NoProfile -File scripts\build.ps1
pause
exit /b 1
