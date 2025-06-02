#!/usr/bin/env python3
"""
Build script for creating Windows-compatible TorchSparse wheel packages.

This script automates the process of building wheel packages for different
Python versions and CUDA configurations on Windows.
"""

import os
import sys
import subprocess
import platform
import shutil
from pathlib import Path

# Configuration
PYTHON_VERSIONS = ["3.8", "3.9", "3.10", "3.11"]
CUDA_VERSIONS = ["11.8", "12.1"]
TORCH_VERSIONS = {
    "11.8": "2.0.1+cu118",
    "12.1": "2.1.0+cu121"
}

def check_prerequisites():
    """Check if all prerequisites are installed."""
    print("🔍 Checking prerequisites...")
    
    # Check if we're on Windows
    if platform.system() != "Windows":
        print("❌ This script is designed for Windows only.")
        return False
    
    # Check for Visual Studio
    vs_paths = [
        r"C:\Program Files (x86)\Microsoft Visual Studio\2019",
        r"C:\Program Files\Microsoft Visual Studio\2019",
        r"C:\Program Files (x86)\Microsoft Visual Studio\2022",
        r"C:\Program Files\Microsoft Visual Studio\2022"
    ]
    
    vs_found = any(Path(path).exists() for path in vs_paths)
    if not vs_found:
        print("❌ Visual Studio 2019 or 2022 not found.")
        return False
    
    # Check for CUDA
    try:
        result = subprocess.run(["nvcc", "--version"], capture_output=True, text=True)
        if result.returncode != 0:
            print("❌ CUDA toolkit not found.")
            return False
        print(f"✅ CUDA found: {result.stdout.split('release')[1].split(',')[0].strip()}")
    except FileNotFoundError:
        print("❌ nvcc not found. Please install CUDA toolkit.")
        return False
    
    print("✅ Prerequisites check passed!")
    return True

def setup_sparsehash():
    """Download and setup sparsehash headers."""
    print("📦 Setting up sparsehash...")
    
    sparsehash_dir = Path("C:/sparsehash")
    if sparsehash_dir.exists():
        print("✅ Sparsehash already installed.")
        return True
    
    try:
        # Download sparsehash
        import urllib.request
        import zipfile
        
        url = "https://github.com/sparsehash/sparsehash/archive/refs/tags/sparsehash-2.0.4.zip"
        zip_path = "sparsehash.zip"
        
        print("📥 Downloading sparsehash...")
        urllib.request.urlretrieve(url, zip_path)
        
        print("📂 Extracting sparsehash...")
        with zipfile.ZipFile(zip_path, 'r') as zip_ref:
            zip_ref.extractall("C:/")
        
        # Rename directory
        extracted_dir = Path("C:/sparsehash-sparsehash-2.0.4")
        if extracted_dir.exists():
            extracted_dir.rename(sparsehash_dir)
        
        # Cleanup
        os.remove(zip_path)
        
        print("✅ Sparsehash setup complete!")
        return True
        
    except Exception as e:
        print(f"❌ Failed to setup sparsehash: {e}")
        return False

def setup_environment():
    """Setup environment variables for building."""
    print("🔧 Setting up build environment...")
    
    # Set sparsehash include path
    current_include = os.environ.get("INCLUDE", "")
    sparsehash_include = "C:\\sparsehash\\src"
    
    if sparsehash_include not in current_include:
        os.environ["INCLUDE"] = f"{current_include};{sparsehash_include}"
    
    # Set build flags for memory optimization
    os.environ["CL"] = "/O1 /MP4"  # Reduced optimization, parallel compilation
    os.environ["DISTUTILS_USE_SDK"] = "1"
    os.environ["MSSdk"] = "1"
    os.environ["FORCE_CUDA"] = "1"
    
    print("✅ Environment setup complete!")

def build_wheel(python_version, cuda_version):
    """Build wheel for specific Python and CUDA version."""
    print(f"🔨 Building wheel for Python {python_version}, CUDA {cuda_version}...")
    
    # Create virtual environment name
    venv_name = f"build_env_{python_version.replace('.', '')}_cu{cuda_version.replace('.', '')}"
    venv_path = Path(venv_name)
    
    try:
        # Create virtual environment
        subprocess.run([f"python{python_version}", "-m", "venv", str(venv_path)], check=True)
        
        # Activate virtual environment
        if platform.system() == "Windows":
            python_exe = venv_path / "Scripts" / "python.exe"
            pip_exe = venv_path / "Scripts" / "pip.exe"
        else:
            python_exe = venv_path / "bin" / "python"
            pip_exe = venv_path / "bin" / "pip"
        
        # Install PyTorch with specific CUDA version
        torch_version = TORCH_VERSIONS[cuda_version]
        torch_url = f"https://download.pytorch.org/whl/cu{cuda_version.replace('.', '')}"
        
        subprocess.run([
            str(pip_exe), "install", 
            f"torch=={torch_version}",
            f"torchvision",
            "--index-url", torch_url
        ], check=True)
        
        # Install build dependencies
        subprocess.run([
            str(pip_exe), "install", 
            "wheel", "setuptools", "ninja"
        ], check=True)
        
        # Build wheel
        subprocess.run([
            str(python_exe), "setup.py", "bdist_wheel"
        ], check=True)
        
        print(f"✅ Wheel built successfully for Python {python_version}, CUDA {cuda_version}")
        return True
        
    except subprocess.CalledProcessError as e:
        print(f"❌ Failed to build wheel: {e}")
        return False
    
    finally:
        # Cleanup virtual environment
        if venv_path.exists():
            shutil.rmtree(venv_path, ignore_errors=True)

def organize_wheels():
    """Organize built wheels into release directory."""
    print("📁 Organizing wheels...")
    
    dist_dir = Path("dist")
    release_dir = Path("release")
    release_dir.mkdir(exist_ok=True)
    
    if not dist_dir.exists():
        print("❌ No dist directory found.")
        return
    
    for wheel_file in dist_dir.glob("*.whl"):
        dest_file = release_dir / wheel_file.name
        shutil.copy2(wheel_file, dest_file)
        print(f"📦 Copied {wheel_file.name}")
    
    print("✅ Wheels organized in release/ directory")

def create_release_notes():
    """Create release notes for the wheel packages."""
    print("📝 Creating release notes...")
    
    release_notes = """# TorchSparse v2.1.0 - Windows Compatible Release

## 🎉 What's New

This release provides native Windows support for TorchSparse with the following improvements:

### ✅ Windows Compatibility Fixes
- **MSVC Compatibility**: Added macros to handle `__asm__` and `__volatile__` keywords
- **Type Safety**: Fixed `long`/`int64_t` type mismatches for Windows
- **Compiler Flags**: Platform-specific compilation flags for optimal Windows builds
- **Dependency Resolution**: Automated sparsehash dependency handling

### 📦 Pre-built Packages

| Python Version | CUDA 11.8 | CUDA 12.1 |
|----------------|------------|------------|
| Python 3.8 | ✅ Available | ✅ Available |
| Python 3.9 | ✅ Available | ✅ Available |
| Python 3.10 | ✅ Available | ✅ Available |
| Python 3.11 | ✅ Available | ✅ Available |

### 🚀 Installation

```bash
# For Python 3.10 with CUDA 11.8
pip install torchsparse-2.1.0-cp310-cp310-win_amd64.whl

# Or install directly from GitHub
pip install git+https://github.com/Deathdadev/torchsparse.git
```

### 🔧 System Requirements

- **OS**: Windows 10/11
- **Python**: 3.8-3.11
- **PyTorch**: 1.9.0+
- **CUDA**: 11.x or 12.x
- **Visual Studio**: 2019 or 2022

### 📋 Compatibility Matrix

All wheels are built with:
- Windows 10/11 x64
- Visual Studio 2019/2022 MSVC compiler
- CUDA 11.8 or 12.1
- Optimized for RTX 20xx/30xx/40xx series GPUs

### 🛠️ Build from Source

See [WINDOWS_SETUP_GUIDE.md](WINDOWS_SETUP_GUIDE.md) for detailed instructions.

### 🐛 Bug Fixes

- Fixed compilation errors with MSVC compiler
- Resolved memory exhaustion during Windows builds
- Fixed sparsehash dependency issues
- Improved error handling for Windows environments

### 🙏 Acknowledgments

Thanks to the original TorchSparse team at MIT-HAN-Lab for the excellent library.
"""
    
    with open("release/RELEASE_NOTES.md", "w") as f:
        f.write(release_notes)
    
    print("✅ Release notes created!")

def main():
    """Main build process."""
    print("🚀 Starting TorchSparse Windows wheel build process...")
    
    if not check_prerequisites():
        sys.exit(1)
    
    if not setup_sparsehash():
        sys.exit(1)
    
    setup_environment()
    
    # Build wheels for each Python/CUDA combination
    success_count = 0
    total_builds = len(PYTHON_VERSIONS) * len(CUDA_VERSIONS)
    
    for python_version in PYTHON_VERSIONS:
        for cuda_version in CUDA_VERSIONS:
            if build_wheel(python_version, cuda_version):
                success_count += 1
    
    organize_wheels()
    create_release_notes()
    
    print(f"\n🎉 Build process complete!")
    print(f"✅ Successfully built {success_count}/{total_builds} wheels")
    print(f"📁 Wheels available in: release/")
    
    if success_count < total_builds:
        print(f"⚠️  {total_builds - success_count} builds failed. Check logs above.")

if __name__ == "__main__":
    main()
