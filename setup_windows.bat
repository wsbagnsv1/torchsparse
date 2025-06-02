@echo off
REM TorchSparse Windows Setup Script
REM This script automates the setup process for TorchSparse on Windows

echo ========================================
echo TorchSparse Windows Setup Script
echo ========================================
echo.

REM Check if running as administrator
net session >nul 2>&1
if %errorLevel% == 0 (
    echo Running as Administrator: YES
) else (
    echo Running as Administrator: NO
    echo Note: Some operations may require administrator privileges
)
echo.

REM Check Python installation
echo Checking Python installation...
python --version >nul 2>&1
if %errorLevel% == 0 (
    for /f "tokens=2" %%i in ('python --version 2^>^&1') do set PYTHON_VERSION=%%i
    echo Python found: %PYTHON_VERSION%
) else (
    echo ERROR: Python not found in PATH
    echo Please install Python 3.8-3.11 from https://python.org
    pause
    exit /b 1
)
echo.

REM Check CUDA installation
echo Checking CUDA installation...
nvcc --version >nul 2>&1
if %errorLevel% == 0 (
    for /f "tokens=5" %%i in ('nvcc --version ^| findstr "release"') do set CUDA_VERSION=%%i
    echo CUDA found: %CUDA_VERSION%
) else (
    echo WARNING: CUDA not found in PATH
    echo TorchSparse will only work in CPU mode
    echo To install CUDA, visit: https://developer.nvidia.com/cuda-downloads
)
echo.

REM Check Visual Studio
echo Checking Visual Studio...
if exist "C:\Program Files (x86)\Microsoft Visual Studio\2019" (
    echo Visual Studio 2019 found
    set VS_FOUND=1
) else if exist "C:\Program Files\Microsoft Visual Studio\2019" (
    echo Visual Studio 2019 found
    set VS_FOUND=1
) else if exist "C:\Program Files (x86)\Microsoft Visual Studio\2022" (
    echo Visual Studio 2022 found
    set VS_FOUND=1
) else if exist "C:\Program Files\Microsoft Visual Studio\2022" (
    echo Visual Studio 2022 found
    set VS_FOUND=1
) else (
    echo WARNING: Visual Studio not found
    echo Please install Visual Studio Build Tools 2019 or 2022
    set VS_FOUND=0
)
echo.

REM Setup sparsehash
echo Setting up sparsehash dependency...
if exist "C:\sparsehash" (
    echo Sparsehash already installed at C:\sparsehash
) else (
    echo Downloading sparsehash...
    powershell -Command "Invoke-WebRequest -Uri 'https://github.com/sparsehash/sparsehash/archive/refs/tags/sparsehash-2.0.4.zip' -OutFile 'sparsehash.zip'"
    
    if exist "sparsehash.zip" (
        echo Extracting sparsehash...
        powershell -Command "Expand-Archive -Path 'sparsehash.zip' -DestinationPath 'C:\'"
        powershell -Command "Rename-Item 'C:\sparsehash-sparsehash-2.0.4' 'C:\sparsehash'"
        del sparsehash.zip
        echo Sparsehash installed successfully
    ) else (
        echo ERROR: Failed to download sparsehash
        echo Please check your internet connection
        pause
        exit /b 1
    )
)
echo.

REM Set environment variables
echo Setting environment variables...
setx INCLUDE "%INCLUDE%;C:\sparsehash\src" >nul 2>&1
set INCLUDE=%INCLUDE%;C:\sparsehash\src
echo Environment variables set
echo.

REM Installation options
echo ========================================
echo Installation Options
echo ========================================
echo 1. Install pre-built wheel (Recommended)
echo 2. Build from source
echo 3. Install from GitHub directly
echo 4. Exit
echo.
set /p choice="Choose an option (1-4): "

if "%choice%"=="1" goto install_wheel
if "%choice%"=="2" goto build_source
if "%choice%"=="3" goto install_github
if "%choice%"=="4" goto end
echo Invalid choice, exiting...
goto end

:install_wheel
echo.
echo Installing pre-built wheel...
echo.
echo Available Python versions:
echo - Python 3.8: torchsparse-2.1.0-cp38-cp38-win_amd64.whl
echo - Python 3.9: torchsparse-2.1.0-cp39-cp39-win_amd64.whl
echo - Python 3.10: torchsparse-2.1.0-cp310-cp310-win_amd64.whl
echo - Python 3.11: torchsparse-2.1.0-cp311-cp311-win_amd64.whl
echo.

REM Detect Python version and suggest appropriate wheel
for /f "tokens=2 delims=." %%i in ('python --version 2^>^&1') do set PY_MAJOR=%%i
for /f "tokens=3 delims=." %%i in ('python --version 2^>^&1') do set PY_MINOR=%%i

set WHEEL_URL=https://github.com/Deathdadev/torchsparse/releases/download/v2.1.0-windows/torchsparse-2.1.0-cp%PY_MAJOR%%PY_MINOR%-cp%PY_MAJOR%%PY_MINOR%-win_amd64.whl

echo Suggested wheel for your Python version: %WHEEL_URL%
echo.
set /p confirm="Install this wheel? (y/n): "
if /i "%confirm%"=="y" (
    pip install %WHEEL_URL%
    goto verify
) else (
    echo Installation cancelled
    goto end
)

:build_source
echo.
echo Building from source...
if %VS_FOUND%==0 (
    echo ERROR: Visual Studio is required for building from source
    echo Please install Visual Studio Build Tools and run this script again
    pause
    goto end
)

echo Upgrading pip and installing build dependencies...
pip install --upgrade pip setuptools wheel ninja

echo Building TorchSparse...
pip install . --no-build-isolation --verbose
goto verify

:install_github
echo.
echo Installing directly from GitHub...
if %VS_FOUND%==0 (
    echo ERROR: Visual Studio is required for building from source
    echo Please install Visual Studio Build Tools and run this script again
    pause
    goto end
)

echo Installing from GitHub repository...
pip install git+https://github.com/Deathdadev/torchsparse.git --no-build-isolation
goto verify

:verify
echo.
echo ========================================
echo Verifying Installation
echo ========================================
echo.

echo Running verification script...
python verify_installation.py

if %errorLevel% == 0 (
    echo.
    echo ========================================
    echo Installation Successful!
    echo ========================================
    echo TorchSparse has been installed and verified successfully.
    echo You can now use TorchSparse in your Python projects.
) else (
    echo.
    echo ========================================
    echo Installation Issues Detected
    echo ========================================
    echo Please check the error messages above.
    echo For troubleshooting, see TROUBLESHOOTING.md
)
echo.

:end
echo.
echo Setup script completed.
echo For more information, see:
echo - WINDOWS_SETUP_GUIDE.md
echo - TROUBLESHOOTING.md
echo - https://github.com/Deathdadev/torchsparse
echo.
pause
