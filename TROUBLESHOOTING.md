# TorchSparse Windows Troubleshooting Guide

This guide addresses common issues encountered when building or installing TorchSparse on Windows.

## 🚨 Common Build Errors

### 1. Missing 'google/dense_hash_map' Error

**Error Message:**
```
fatal error C1083: Cannot open include file: 'google/dense_hash_map': No such file or directory
```

**Root Cause:** Missing sparsehash dependency

**Solutions:**

#### Option A: Quick Fix (Recommended)
```powershell
# Download pre-built headers
Invoke-WebRequest -Uri "https://github.com/sparsehash/sparsehash/archive/refs/tags/sparsehash-2.0.4.zip" -OutFile "sparsehash.zip"
Expand-Archive -Path "sparsehash.zip" -DestinationPath "C:\"
Rename-Item "C:\sparsehash-sparsehash-2.0.4" "C:\sparsehash"

# Set environment variable
$env:INCLUDE = "$env:INCLUDE;C:\sparsehash\src"
```

#### Option B: Using vcpkg
```powershell
git clone https://github.com/Microsoft/vcpkg.git C:\vcpkg
cd C:\vcpkg
.\bootstrap-vcpkg.bat
.\vcpkg install sparsehash:x64-windows
$env:CMAKE_TOOLCHAIN_FILE = "C:\vcpkg\scripts\buildsystems\vcpkg.cmake"
```

#### Option C: Manual Build
```powershell
git clone https://github.com/sparsehash/sparsehash.git C:\sparsehash-src
cd C:\sparsehash-src
mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=C:\sparsehash -A x64
cmake --build . --config Release
cmake --install .
$env:INCLUDE = "$env:INCLUDE;C:\sparsehash\include"
```

### 2. Compiler Out of Heap Space

**Error Message:**
```
fatal error C1060: compiler is out of heap space
catastrophic error: out of memory
```

**Root Cause:** Insufficient memory during compilation

**Solutions:**

#### Immediate Fixes:
```powershell
# 1. Reduce optimization level
$env:CL = "/O1 /MP2"  # Use O1 instead of O2, limit parallel jobs

# 2. Increase virtual memory
# Go to System Properties > Advanced > Performance Settings > Advanced > Virtual Memory
# Set to 16GB+ or let Windows manage automatically

# 3. Close unnecessary applications
Get-Process | Where-Object {$_.WorkingSet -gt 500MB} | Stop-Process -Force
```

#### Long-term Solutions:
1. **Upgrade RAM**: 16GB+ recommended for building
2. **Use SSD**: Faster virtual memory access
3. **Use pre-built wheels**: Avoid compilation entirely

### 3. CUDA Architecture Mismatch

**Error Message:**
```
nvcc fatal : Unsupported gpu architecture 'compute_XX'
```

**Solution:**
```powershell
# Check your GPU architecture
nvidia-smi

# Set appropriate architectures (adjust based on your GPU)
$env:TORCH_CUDA_ARCH_LIST = "7.5;8.0;8.6;8.9"

# Common GPU architectures:
# RTX 20xx series: 7.5
# RTX 30xx series: 8.6
# RTX 40xx series: 8.9
```

### 4. Visual Studio Not Found

**Error Message:**
```
Microsoft Visual C++ 14.0 is required
```

**Solutions:**

#### Option A: Install Visual Studio Build Tools
```powershell
# Download and install Visual Studio Build Tools 2019 or 2022
# Include: C++ build tools, Windows 10/11 SDK, CMake tools
```

#### Option B: Set Environment Variables
```powershell
$env:DISTUTILS_USE_SDK = "1"
$env:MSSdk = "1"
$env:VS160COMNTOOLS = "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\Common7\Tools\"
```

### 5. PyTorch Version Conflicts

**Error Message:**
```
RuntimeError: The detected CUDA version (X.X) mismatches the version that was used to compile PyTorch (Y.Y)
```

**Solution:**
```bash
# Uninstall existing PyTorch
pip uninstall torch torchvision torchaudio

# Install matching CUDA version
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
# or for CUDA 12.1:
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
```

## 🔧 Environment Setup Issues

### Python Environment Problems

**Issue:** Multiple Python installations causing conflicts

**Solution:**
```powershell
# Use virtual environments
python -m venv torchsparse_env
.\torchsparse_env\Scripts\activate
pip install --upgrade pip setuptools wheel
```

### Path Issues

**Issue:** Tools not found in PATH

**Solution:**
```powershell
# Add to PATH (adjust paths as needed)
$env:PATH += ";C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v11.8\bin"
$env:PATH += ";C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\MSBuild\Current\Bin"
```

## 🚀 Performance Optimization

### Build Speed Improvements

```powershell
# Use ninja build system
pip install ninja

# Parallel compilation (adjust based on CPU cores)
$env:CL = "/MP8"  # Use 8 parallel jobs

# Use ccache if available
$env:CC = "ccache cl"
$env:CXX = "ccache cl"
```

### Memory Usage Optimization

```powershell
# Reduce memory usage during build
$env:CL = "/O1 /MP2 /Zm200"  # Limit memory per compilation unit

# Build in release mode only
$env:CMAKE_BUILD_TYPE = "Release"
```

## 🔍 Debugging Build Issues

### Enable Verbose Output

```bash
# Verbose pip installation
pip install . --verbose --no-build-isolation

# Verbose setup.py
python setup.py build_ext --verbose
```

### Check System Information

```python
# System info script
import torch
import platform
import subprocess

print(f"Platform: {platform.platform()}")
print(f"Python: {platform.python_version()}")
print(f"PyTorch: {torch.__version__}")
print(f"CUDA Available: {torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"CUDA Version: {torch.version.cuda}")
    print(f"GPU: {torch.cuda.get_device_name()}")

# Check CUDA toolkit
try:
    result = subprocess.run(["nvcc", "--version"], capture_output=True, text=True)
    print(f"NVCC: {result.stdout}")
except:
    print("NVCC: Not found")
```

## 🆘 When All Else Fails

### Use Pre-built Wheels

Instead of building from source, use our pre-built wheels:

```bash
# Download appropriate wheel from releases
pip install https://github.com/Deathdadev/torchsparse/releases/download/v2.1.0-windows/torchsparse-2.1.0-cp310-cp310-win_amd64.whl
```

### Alternative Installation Methods

```bash
# Try different installation flags
pip install git+https://github.com/Deathdadev/torchsparse.git --no-build-isolation --no-cache-dir

# Or use conda-forge (if available)
conda install -c conda-forge torchsparse
```

### Docker Alternative

If native Windows installation continues to fail:

```dockerfile
# Use Windows containers with pre-built environment
FROM mcr.microsoft.com/windows/servercore:ltsc2019
# ... setup Python, CUDA, and dependencies
```

## 📞 Getting Help

If you're still experiencing issues:

1. **Check existing issues**: [GitHub Issues](https://github.com/Deathdadev/torchsparse/issues)
2. **Create new issue** with:
   - Complete error log
   - System information (use script above)
   - Steps to reproduce
   - Environment details

3. **Include this information**:
   ```bash
   python -c "import torch; print(f'PyTorch: {torch.__version__}, CUDA: {torch.version.cuda}')"
   nvcc --version
   cl
   ```

## 📚 Additional Resources

- [Official PyTorch Installation Guide](https://pytorch.org/get-started/locally/)
- [CUDA Installation Guide](https://docs.nvidia.com/cuda/cuda-installation-guide-microsoft-windows/)
- [Visual Studio Build Tools](https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022)
- [Windows SDK](https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/)
