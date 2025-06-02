# Windows-Compatible TorchSparse Setup Guide

This guide provides comprehensive instructions for installing the Windows-compatible version of TorchSparse that includes fixes for MSVC compilation issues, type compatibility, and dependency resolution.

## 🎯 Quick Start (Recommended)

For most users, we recommend using the pre-built wheel packages:

```bash
pip install https://github.com/Deathdadev/torchsparse/releases/download/v2.1.0-windows/torchsparse-2.1.0-cp310-cp310-win_amd64.whl
```

## 📋 Prerequisites

### Required Software
- **Python**: 3.8, 3.9, 3.10, or 3.11
- **PyTorch**: 1.9.0+ with CUDA support
- **CUDA Toolkit**: 11.x or 12.x
- **Microsoft Visual Studio**: 2019 or 2022 with C++ build tools
- **Git**: For cloning repositories

### Verify Prerequisites
```bash
# Check Python version
python --version

# Check PyTorch and CUDA
python -c "import torch; print(f'PyTorch: {torch.__version__}, CUDA: {torch.version.cuda}')"

# Check CUDA toolkit
nvcc --version
```

## 🔧 Dependency Installation

### Option 1: Sparsehash via vcpkg (Recommended)
```powershell
# Install vcpkg
git clone https://github.com/Microsoft/vcpkg.git C:\vcpkg
cd C:\vcpkg
.\bootstrap-vcpkg.bat

# Install sparsehash
.\vcpkg install sparsehash:x64-windows

# Set environment variable
$env:VCPKG_ROOT = "C:\vcpkg"
```

### Option 2: Pre-built Headers (Quick Setup)
```powershell
# Download and extract sparsehash
Invoke-WebRequest -Uri "https://github.com/sparsehash/sparsehash/archive/refs/tags/sparsehash-2.0.4.zip" -OutFile "sparsehash.zip"
Expand-Archive -Path "sparsehash.zip" -DestinationPath "C:\"
Rename-Item "C:\sparsehash-sparsehash-2.0.4" "C:\sparsehash"

# Set include path
$env:INCLUDE = "$env:INCLUDE;C:\sparsehash\src"
```

### Option 3: Manual Build from Source
```powershell
git clone https://github.com/sparsehash/sparsehash.git C:\sparsehash-src
cd C:\sparsehash-src
mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=C:\sparsehash -A x64
cmake --build . --config Release
cmake --install .
```

## 🚀 Installation Methods

### Method 1: Pre-built Wheels (Easiest)

Choose the appropriate wheel for your Python version:

| Python Version | Download Link |
|----------------|---------------|
| Python 3.8 | [torchsparse-2.1.0-cp38-cp38-win_amd64.whl](https://github.com/Deathdadev/torchsparse/releases/download/v2.1.0-windows/torchsparse-2.1.0-cp38-cp38-win_amd64.whl) |
| Python 3.9 | [torchsparse-2.1.0-cp39-cp39-win_amd64.whl](https://github.com/Deathdadev/torchsparse/releases/download/v2.1.0-windows/torchsparse-2.1.0-cp39-cp39-win_amd64.whl) |
| Python 3.10 | [torchsparse-2.1.0-cp310-cp310-win_amd64.whl](https://github.com/Deathdadev/torchsparse/releases/download/v2.1.0-windows/torchsparse-2.1.0-cp310-cp310-win_amd64.whl) |
| Python 3.11 | [torchsparse-2.1.0-cp311-cp311-win_amd64.whl](https://github.com/Deathdadev/torchsparse/releases/download/v2.1.0-windows/torchsparse-2.1.0-cp311-cp311-win_amd64.whl) |

```bash
pip install [wheel_url_from_table_above]
```

### Method 2: Build from Source

```bash
# Clone the Windows-compatible repository
git clone https://github.com/Deathdadev/torchsparse.git
cd torchsparse

# Install with build isolation disabled for better control
pip install . --no-build-isolation --verbose
```

### Method 3: Direct GitHub Installation

```bash
pip install git+https://github.com/Deathdadev/torchsparse.git@f1787ee --no-build-isolation
```

## 🔍 Verification

Test your installation:

```python
import torch
import torchsparse

# Basic functionality test
print(f"TorchSparse version: {torchsparse.__version__}")
print(f"CUDA available: {torch.cuda.is_available()}")

# Create a simple sparse tensor
coords = torch.randint(0, 10, (100, 4))
feats = torch.randn(100, 16)
sparse_tensor = torchsparse.SparseTensor(coords=coords, feats=feats)
print(f"Sparse tensor created successfully: {sparse_tensor.shape}")
```

## 🛠️ Troubleshooting

### Error: "Cannot open include file: 'google/dense_hash_map'"

**Solution**: Install sparsehash using one of the methods above, then:

```powershell
# If using vcpkg
$env:CMAKE_TOOLCHAIN_FILE = "C:\vcpkg\scripts\buildsystems\vcpkg.cmake"

# If using manual installation
$env:INCLUDE = "$env:INCLUDE;C:\sparsehash\src"
```

### Error: "fatal error C1060: compiler is out of heap space"

**Solutions**:
1. **Increase virtual memory**: Set page file to 16GB+
2. **Close other applications** during compilation
3. **Use parallel compilation**: Add `/MP` flag
4. **Build with reduced optimization**: Use `/O1` instead of `/O2`

```powershell
# Set environment variable for reduced optimization
$env:CL = "/O1 /MP"
```

### Error: "Compilation terminated" or "out of memory"

**Solutions**:
1. **Restart your system** to free memory
2. **Use pre-built wheels** instead of building from source
3. **Build in parts**: Install dependencies separately

### CUDA Architecture Mismatch

If you get CUDA architecture errors:

```bash
# Check your GPU architecture
nvidia-smi

# Set appropriate CUDA architecture
$env:TORCH_CUDA_ARCH_LIST = "7.5;8.0;8.6;8.9"  # Adjust based on your GPU
```

## 🔧 Advanced Configuration

### Custom Compiler Flags

For advanced users who need custom compilation:

```python
# Create setup_local.py with custom flags
import os
os.environ['CXXFLAGS'] = '/O1 /MP4'  # Reduced optimization, 4 parallel jobs
os.environ['NVCCFLAGS'] = '-O2'      # CUDA optimization
```

### Environment Variables

Set these for consistent builds:

```powershell
$env:DISTUTILS_USE_SDK = "1"
$env:MSSdk = "1"
$env:TORCH_CUDA_ARCH_LIST = "7.5;8.0;8.6;8.9"
$env:FORCE_CUDA = "1"
```

## 📊 Compatibility Matrix

| Component | Supported Versions |
|-----------|-------------------|
| Python | 3.8, 3.9, 3.10, 3.11 |
| PyTorch | 1.9.0+ |
| CUDA | 11.1, 11.3, 11.6, 11.7, 11.8, 12.0, 12.1 |
| Windows | 10, 11 |
| Visual Studio | 2019, 2022 |
| GPU Architectures | SM 7.5+ (RTX 20xx, 30xx, 40xx series) |

## 🆘 Getting Help

If you encounter issues:

1. **Check the troubleshooting section** above
2. **Use pre-built wheels** if building from source fails
3. **Open an issue** at [GitHub Issues](https://github.com/Deathdadev/torchsparse/issues)
4. **Include system information**:
   ```bash
   python -c "import torch; print(torch.__version__, torch.version.cuda)"
   nvcc --version
   ```

## 🔄 Updates

This Windows-compatible version includes:
- ✅ MSVC compatibility macros for inline assembly
- ✅ Fixed long/int64_t type mismatches
- ✅ Platform-specific compiler flags
- ✅ Sparsehash dependency resolution
- ✅ Memory optimization for Windows builds

For the latest updates, check the [releases page](https://github.com/Deathdadev/torchsparse/releases).
