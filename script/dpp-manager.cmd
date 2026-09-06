@echo off
rem Double-click this file to start the DPP Manager on Windows.
rem
rem It does the same three things as the macOS version: check that Docker is
rem running, build the application the first time, and start it with a folder
rem on this computer as its data folder.
setlocal

set "APP=dpp-manager"
set "DATA=%USERPROFILE%\DPP Manager"
if "%DPP_MANAGER_PORT%"=="" set "DPP_MANAGER_PORT=3000"
set "HERE=%~dp0.."

echo DPP Manager
echo ===========
echo.

where docker >nul 2>&1
if errorlevel 1 (
  echo Docker is not installed.
  echo.
  echo Install Docker Desktop from https://www.docker.com/products/docker-desktop
  echo start it once, and then double-click this file again.
  pause
  exit /b 1
)

docker info >nul 2>&1
if errorlevel 1 (
  echo Docker is installed but not running.
  echo.
  echo Start Docker Desktop, wait until its whale icon stops moving,
  echo and then double-click this file again.
  pause
  exit /b 1
)

if not exist "%DATA%" mkdir "%DATA%"
echo Your data folder:  %DATA%
echo Everything the application knows is one file in there.
echo.

docker image inspect %APP% >nul 2>&1
if errorlevel 1 (
  echo Building the application - this happens once and takes a few minutes.
  echo.
  docker build -t %APP% "%HERE%"
  if errorlevel 1 (
    echo.
    echo The build did not finish. The messages above say why.
    pause
    exit /b 1
  )
  echo.
)

docker rm -f %APP% >nul 2>&1

docker run -d --name %APP% -p %DPP_MANAGER_PORT%:3000 -v "%DATA%:/data" %APP% >nul
if errorlevel 1 (
  echo Could not start the application.
  pause
  exit /b 1
)

echo Starting - this takes a few seconds.
timeout /t 8 /nobreak >nul

start "" "http://localhost:%DPP_MANAGER_PORT%"
echo.
echo The application is at  http://localhost:%DPP_MANAGER_PORT%
echo.
echo To stop it later:   docker stop %APP%
echo To start it again:  double-click this file
pause
exit /b 0
