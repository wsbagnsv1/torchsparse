#!/usr/bin/env python3
"""
Build script for creating cross-platform TorchSparse wheel packages.

This script automates the process of building wheel packages for different
Python versions, PyTorch versions, and CUDA configurations on Windows and Linux.
"""

import os
import sys
import subprocess
import platform
import shutil
from pathlib import Path

# Configuration
PYTHON_VERSIONS = ["3.8", "3.9", "3.10", "3.11", "3.12"]
CUDA_VERSIONS = ["11.1", "11.3", "11.6", "11.7", "11.8", "12.0", "12.1", "12.4"]
TORCH_VERSIONS = {
    # PyTorch 1.9.x series
    "11.1": ["1.9.0+cu111", "1.9.1+cu111"],
    "11.3": ["1.9.0+cu111", "1.9.1+cu111"],  # Use cu111 for 11.3

    # PyTorch 1.10.x - 1.13.x series
    "11.6": ["1.10.0+cu113", "1.11.0+cu113", "1.12.0+cu113", "1.13.0+cu116"],
    "11.7": ["1.13.0+cu116", "1.13.1+cu117"],

    # PyTorch 2.0.x series
    "11.8": ["2.0.0+cu118", "2.0.1+cu118"],

    # PyTorch 2.1.x - 2.4.x series
    "12.0": ["2.1.0+cu121", "2.2.0+cu121", "2.3.0+cu121", "2.4.0+cu121"],
    "12.1": ["2.1.0+cu121", "2.2.0+cu121", "2.3.0+cu121", "2.4.0+cu121"],
    "12.4": ["2.4.0+cu124", "2.5.0+cu124"]  # Latest versions
}

def check_prerequisites():
    """Check if all prerequisites are installed."""
    print("🔍 Checking prerequisites...")

    current_os = platform.system()
    print(f"Operating System: {current_os}")

    if current_os == "Windows":
        return check_windows_prerequisites()
    elif current_os == "Linux":
        return check_linux_prerequisites()
    else:
        print(f"❌ Unsupported operating system: {current_os}")
        print("This script supports Windows and Linux only.")
        return False

def check_windows_prerequisites():
    """Check Windows-specific prerequisites."""
    print("Checking Windows prerequisites...")

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
        print("Please install Visual Studio Build Tools with C++ support.")
        return False
    print("✅ Visual Studio found")

    return check_common_prerequisites()

def check_linux_prerequisites():
    """Check Linux-specific prerequisites."""
    print("Checking Linux prerequisites...")

    # Check for GCC
    try:
        result = subprocess.run(["gcc", "--version"], capture_output=True, text=True)
        if result.returncode != 0:
            print("❌ GCC not found.")
            return False
        gcc_version = result.stdout.split('\n')[0]
        print(f"✅ GCC found: {gcc_version}")
    except FileNotFoundError:
        print("❌ GCC not found. Please install build-essential.")
        return False

    # Check for development headers
    dev_packages = [
        "/usr/include/python3.8",
        "/usr/include/python3.9",
        "/usr/include/python3.10",
        "/usr/include/python3.11",
        "/usr/include/python3.12"
    ]

    python_dev_found = any(Path(path).exists() for path in dev_packages)
    if not python_dev_found:
        print("⚠️  Python development headers may be missing.")
        print("Consider installing python3-dev or python3-devel")

    return check_common_prerequisites()

def check_common_prerequisites():
    """Check prerequisites common to both platforms."""
    # Check for CUDA
    try:
        result = subprocess.run(["nvcc", "--version"], capture_output=True, text=True)
        if result.returncode != 0:
            print("❌ CUDA toolkit not found.")
            return False
        cuda_info = result.stdout.split('release')[1].split(',')[0].strip()
        print(f"✅ CUDA found: {cuda_info}")
    except FileNotFoundError:
        print("❌ nvcc not found. Please install CUDA toolkit.")
        return False

    print("✅ Prerequisites check passed!")
    return True

def setup_sparsehash():
    """Download and setup sparsehash headers."""
    print("📦 Setting up sparsehash...")

    current_os = platform.system()

    if current_os == "Windows":
        return setup_sparsehash_windows()
    elif current_os == "Linux":
        return setup_sparsehash_linux()
    else:
        print(f"❌ Unsupported OS for sparsehash setup: {current_os}")
        return False

def setup_sparsehash_windows():
    """Setup sparsehash on Windows."""
    sparsehash_dir = Path("C:/sparsehash")
    if sparsehash_dir.exists():
        print("✅ Sparsehash already installed.")
        return True

    try:
        import urllib.request
        import zipfile

        url = "https://github.com/sparsehash/sparsehash/archive/refs/tags/sparsehash-2.0.4.zip"
        zip_path = "sparsehash.zip"

        print("📥 Downloading sparsehash...")
        urllib.request.urlretrieve(url, zip_path)

        print("📂 Extracting sparsehash...")
        with zipfile.ZipFile(zip_path, 'r') as zip_ref:
            zip_ref.extractall("C:/")

        extracted_dir = Path("C:/sparsehash-sparsehash-2.0.4")
        if extracted_dir.exists():
            extracted_dir.rename(sparsehash_dir)

        os.remove(zip_path)
        print("✅ Sparsehash setup complete!")
        return True

    except Exception as e:
        print(f"❌ Failed to setup sparsehash: {e}")
        return False

def setup_sparsehash_linux():
    """Setup sparsehash on Linux."""
    # Check if sparsehash is available via package manager
    try:
        # Try to find sparsehash in system
        result = subprocess.run(["pkg-config", "--exists", "libsparsehash"],
                              capture_output=True)
        if result.returncode == 0:
            print("✅ Sparsehash found via pkg-config")
            return True
    except FileNotFoundError:
        pass

    # Check common installation paths
    common_paths = [
        "/usr/include/sparsehash",
        "/usr/local/include/sparsehash",
        "/usr/include/google/sparse_hash_map",
        "/usr/local/include/google/sparse_hash_map"
    ]

    if any(Path(path).exists() for path in common_paths):
        print("✅ Sparsehash found in system paths")
        return True

    # Try to install via package manager
    print("📦 Attempting to install sparsehash via package manager...")

    # Try different package managers with and without sudo
    package_managers = [
        (["apt-get", "update"], ["apt-get", "install", "-y", "libsparsehash-dev"]),
        (["yum", "update"], ["yum", "install", "-y", "sparsehash-devel"]),
        (["dnf", "update"], ["dnf", "install", "-y", "sparsehash-devel"]),
        (["pacman", "-Sy"], ["pacman", "-S", "--noconfirm", "sparsehash"])
    ]

    for update_cmd, install_cmd in package_managers:
        try:
            print(f"Trying {install_cmd[0]} with sudo...")
            # Try with sudo first
            subprocess.run(["sudo"] + update_cmd, check=True, capture_output=True)
            subprocess.run(["sudo"] + install_cmd, check=True, capture_output=True)
            print(f"✅ Sparsehash installed via sudo {install_cmd[0]}")
            return True
        except (subprocess.CalledProcessError, FileNotFoundError):
            try:
                print(f"Trying {install_cmd[0]} without sudo...")
                # Try without sudo as fallback
                subprocess.run(update_cmd, check=True, capture_output=True)
                subprocess.run(install_cmd, check=True, capture_output=True)
                print(f"✅ Sparsehash installed via {install_cmd[0]} (no sudo)")
                return True
            except (subprocess.CalledProcessError, FileNotFoundError):
                continue

    # If package manager fails, build from source
    print("📦 Building sparsehash from source...")
    return build_sparsehash_from_source()

def build_sparsehash_from_source():
    """Build sparsehash from source on Linux."""
    try:
        import urllib.request
        import tarfile

        url = "https://github.com/sparsehash/sparsehash/archive/refs/tags/sparsehash-2.0.4.tar.gz"
        tar_path = "sparsehash.tar.gz"

        print("📥 Downloading sparsehash source...")
        urllib.request.urlretrieve(url, tar_path)

        print("📂 Extracting sparsehash...")
        with tarfile.open(tar_path, 'r:gz') as tar_ref:
            tar_ref.extractall()

        # Build and install
        build_dir = Path("sparsehash-sparsehash-2.0.4")
        if build_dir.exists():
            os.chdir(build_dir)

            # Configure, build, and install
            subprocess.run(["./configure", "--prefix=/usr/local"], check=True)
            subprocess.run(["make"], check=True)

            # Try to install with sudo, fallback to user install if sudo fails
            try:
                subprocess.run(["sudo", "make", "install"], check=True)
            except (subprocess.CalledProcessError, FileNotFoundError):
                print("⚠️  sudo not available or failed, trying user install...")
                subprocess.run(["make", "install", f"PREFIX={os.path.expanduser('~/.local')}"], check=True)
                # Add to environment for subsequent builds
                local_include = os.path.expanduser("~/.local/include")
                current_cppflags = os.environ.get("CPPFLAGS", "")
                os.environ["CPPFLAGS"] = f"{current_cppflags} -I{local_include}"

            os.chdir("..")
            shutil.rmtree(build_dir)

        os.remove(tar_path)
        print("✅ Sparsehash built and installed from source!")
        return True

    except Exception as e:
        print(f"❌ Failed to build sparsehash from source: {e}")
        print("Please install sparsehash manually:")
        print("  Ubuntu/Debian: sudo apt-get install libsparsehash-dev")
        print("  CentOS/RHEL: sudo yum install sparsehash-devel")
        print("  Fedora: sudo dnf install sparsehash-devel")
        print("  Arch: sudo pacman -S sparsehash")
        return False

def setup_environment():
    """Setup environment variables for building."""
    print("🔧 Setting up build environment...")

    current_os = platform.system()

    if current_os == "Windows":
        setup_windows_environment()
    elif current_os == "Linux":
        setup_linux_environment()

    # Common environment variables
    os.environ["FORCE_CUDA"] = "1"
    print("✅ Environment setup complete!")

def setup_windows_environment():
    """Setup Windows-specific environment variables."""
    # Set sparsehash include path
    current_include = os.environ.get("INCLUDE", "")
    sparsehash_include = "C:\\sparsehash\\src"

    if sparsehash_include not in current_include:
        os.environ["INCLUDE"] = f"{current_include};{sparsehash_include}"

    # Set build flags for memory optimization
    os.environ["CL"] = "/O1 /MP4"  # Reduced optimization, parallel compilation
    os.environ["DISTUTILS_USE_SDK"] = "1"
    os.environ["MSSdk"] = "1"

def setup_linux_environment():
    """Setup Linux-specific environment variables."""
    # Set compiler flags for optimization
    current_cxxflags = os.environ.get("CXXFLAGS", "")
    current_cflags = os.environ.get("CFLAGS", "")

    # Add optimization and parallel compilation flags
    os.environ["CXXFLAGS"] = f"{current_cxxflags} -O2 -fopenmp"
    os.environ["CFLAGS"] = f"{current_cflags} -O2"

    # Set number of parallel jobs based on CPU count
    import multiprocessing
    num_jobs = min(multiprocessing.cpu_count(), 8)  # Limit to 8 to avoid memory issues
    os.environ["MAX_JOBS"] = str(num_jobs)

def build_wheel(python_version, cuda_version, torch_version=None):
    """Build wheel for specific Python, CUDA, and PyTorch version."""
    if torch_version is None:
        # Use the first (latest) torch version for this CUDA version
        torch_version = TORCH_VERSIONS[cuda_version][0]

    print(f"🔨 Building wheel for Python {python_version}, CUDA {cuda_version}, PyTorch {torch_version}...")

    # Create virtual environment name
    cuda_short = cuda_version.replace('.', '')
    torch_short = torch_version.split('+')[0].replace('.', '')
    venv_name = f"build_env_py{python_version.replace('.', '')}_cu{cuda_short}_torch{torch_short}"
    venv_path = Path(venv_name)

    try:
        # Create virtual environment
        python_cmd = get_python_command(python_version)
        subprocess.run([python_cmd, "-m", "venv", str(venv_path)], check=True)

        # Get executables
        if platform.system() == "Windows":
            python_exe = venv_path / "Scripts" / "python.exe"
            pip_exe = venv_path / "Scripts" / "pip.exe"
        else:
            python_exe = venv_path / "bin" / "python"
            pip_exe = venv_path / "bin" / "pip"

        # Install PyTorch with specific CUDA version
        install_pytorch(pip_exe, torch_version, cuda_version)

        # Install build dependencies
        subprocess.run([
            str(pip_exe), "install",
            "wheel", "setuptools", "ninja"
        ], check=True)

        # Build wheel
        subprocess.run([
            str(python_exe), "setup.py", "bdist_wheel"
        ], check=True)

        print(f"✅ Wheel built successfully for Python {python_version}, CUDA {cuda_version}, PyTorch {torch_version}")
        return True

    except subprocess.CalledProcessError as e:
        print(f"❌ Failed to build wheel: {e}")
        return False

    finally:
        # Cleanup virtual environment
        if venv_path.exists():
            shutil.rmtree(venv_path, ignore_errors=True)

def get_python_command(python_version):
    """Get the appropriate Python command for the version."""
    # Try different Python command formats
    commands = [
        f"python{python_version}",
        f"python{python_version.split('.')[0]}.{python_version.split('.')[1]}",
        "python3",
        "python"
    ]

    for cmd in commands:
        try:
            result = subprocess.run([cmd, "--version"], capture_output=True, text=True)
            if result.returncode == 0 and python_version in result.stdout:
                return cmd
        except FileNotFoundError:
            continue

    # Fallback to just python
    return "python"

def install_pytorch(pip_exe, torch_version, cuda_version):
    """Install PyTorch with the specified version and CUDA support."""
    cuda_short = cuda_version.replace('.', '')

    # Determine the correct index URL based on CUDA version
    if cuda_version.startswith("11."):
        if "cu111" in torch_version:
            index_url = "https://download.pytorch.org/whl/cu111"
        elif "cu113" in torch_version:
            index_url = "https://download.pytorch.org/whl/cu113"
        elif "cu116" in torch_version:
            index_url = "https://download.pytorch.org/whl/cu116"
        elif "cu117" in torch_version:
            index_url = "https://download.pytorch.org/whl/cu117"
        elif "cu118" in torch_version:
            index_url = "https://download.pytorch.org/whl/cu118"
        else:
            index_url = f"https://download.pytorch.org/whl/cu{cuda_short}"
    else:  # CUDA 12.x
        if "cu121" in torch_version:
            index_url = "https://download.pytorch.org/whl/cu121"
        elif "cu124" in torch_version:
            index_url = "https://download.pytorch.org/whl/cu124"
        else:
            index_url = f"https://download.pytorch.org/whl/cu{cuda_short}"

    # Install PyTorch and torchvision
    subprocess.run([
        str(pip_exe), "install",
        f"torch=={torch_version}",
        "--index-url", index_url
    ], check=True)

    # Install torchvision (let pip figure out the compatible version)
    subprocess.run([
        str(pip_exe), "install",
        "torchvision",
        "--index-url", index_url
    ], check=True)

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
    current_os = platform.system()
    print(f"🚀 Starting TorchSparse cross-platform wheel build process on {current_os}...")

    if not check_prerequisites():
        sys.exit(1)

    if not setup_sparsehash():
        sys.exit(1)

    setup_environment()

    # Parse command line arguments for selective building
    import argparse
    parser = argparse.ArgumentParser(description="Build TorchSparse wheels")
    parser.add_argument("--python-versions", nargs="+", default=PYTHON_VERSIONS,
                       help="Python versions to build for")
    parser.add_argument("--cuda-versions", nargs="+", default=CUDA_VERSIONS,
                       help="CUDA versions to build for")
    parser.add_argument("--torch-versions", nargs="+", default=None,
                       help="Specific PyTorch versions to build for")
    parser.add_argument("--build-latest-only", action="store_true",
                       help="Build only the latest PyTorch version for each CUDA version")
    parser.add_argument("--max-parallel", type=int, default=1,
                       help="Maximum number of parallel builds")

    args = parser.parse_args()

    # Build wheels for each combination
    success_count = 0
    total_builds = 0
    failed_builds = []

    for python_version in args.python_versions:
        if python_version not in PYTHON_VERSIONS:
            print(f"⚠️  Skipping unsupported Python version: {python_version}")
            continue

        for cuda_version in args.cuda_versions:
            if cuda_version not in CUDA_VERSIONS:
                print(f"⚠️  Skipping unsupported CUDA version: {cuda_version}")
                continue

            # Get PyTorch versions for this CUDA version
            available_torch_versions = TORCH_VERSIONS.get(cuda_version, [])
            if not available_torch_versions:
                print(f"⚠️  No PyTorch versions available for CUDA {cuda_version}")
                continue

            # Select which PyTorch versions to build
            if args.build_latest_only:
                torch_versions_to_build = [available_torch_versions[0]]  # Latest only
            elif args.torch_versions:
                # Filter to only requested versions that are available
                torch_versions_to_build = [v for v in args.torch_versions
                                         if v in available_torch_versions]
            else:
                torch_versions_to_build = available_torch_versions  # All available

            for torch_version in torch_versions_to_build:
                total_builds += 1
                print(f"\n{'='*60}")
                print(f"Building {total_builds}: Python {python_version}, CUDA {cuda_version}, PyTorch {torch_version}")
                print(f"{'='*60}")

                if build_wheel(python_version, cuda_version, torch_version):
                    success_count += 1
                else:
                    failed_builds.append(f"Python {python_version}, CUDA {cuda_version}, PyTorch {torch_version}")

    organize_wheels()
    create_release_notes()

    print(f"\n🎉 Build process complete!")
    print(f"✅ Successfully built {success_count}/{total_builds} wheels")
    print(f"📁 Wheels available in: release/")

    if failed_builds:
        print(f"\n❌ Failed builds ({len(failed_builds)}):")
        for failed in failed_builds:
            print(f"  - {failed}")
        print("\nCheck the logs above for error details.")

    # Print build matrix summary
    print(f"\n📊 Build Matrix Summary:")
    print(f"  Python versions: {', '.join(args.python_versions)}")
    print(f"  CUDA versions: {', '.join(args.cuda_versions)}")
    print(f"  Platform: {current_os}")
    print(f"  Total combinations: {total_builds}")
    print(f"  Success rate: {success_count/total_builds*100:.1f}%" if total_builds > 0 else "  No builds attempted")

if __name__ == "__main__":
    main()
