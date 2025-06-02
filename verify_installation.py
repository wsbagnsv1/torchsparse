#!/usr/bin/env python3
"""
TorchSparse Installation Verification Script

This script verifies that TorchSparse is properly installed and functioning
on Windows systems. It performs comprehensive tests of core functionality.
"""

import sys
import platform
import subprocess
import traceback
from pathlib import Path

def print_header(title):
    """Print a formatted header."""
    print(f"\n{'='*60}")
    print(f" {title}")
    print(f"{'='*60}")

def print_section(title):
    """Print a formatted section header."""
    print(f"\n{'-'*40}")
    print(f" {title}")
    print(f"{'-'*40}")

def check_system_info():
    """Check and display system information."""
    print_section("System Information")
    
    print(f"Platform: {platform.platform()}")
    print(f"Architecture: {platform.architecture()}")
    print(f"Python Version: {platform.python_version()}")
    print(f"Python Executable: {sys.executable}")
    
    # Check if we're on Windows
    if platform.system() != "Windows":
        print("⚠️  Warning: This verification script is designed for Windows")
        return False
    
    return True

def check_cuda_toolkit():
    """Check CUDA toolkit installation."""
    print_section("CUDA Toolkit")
    
    try:
        result = subprocess.run(["nvcc", "--version"], 
                              capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            version_line = [line for line in result.stdout.split('\n') 
                          if 'release' in line.lower()]
            if version_line:
                print(f"✅ CUDA Toolkit: {version_line[0].strip()}")
                return True
            else:
                print(f"✅ CUDA Toolkit: Found (version parsing failed)")
                return True
        else:
            print(f"❌ CUDA Toolkit: nvcc command failed")
            return False
    except (subprocess.TimeoutExpired, FileNotFoundError):
        print(f"❌ CUDA Toolkit: nvcc not found in PATH")
        return False

def check_pytorch():
    """Check PyTorch installation and CUDA support."""
    print_section("PyTorch")
    
    try:
        import torch
        print(f"✅ PyTorch Version: {torch.__version__}")
        
        # Check CUDA availability
        cuda_available = torch.cuda.is_available()
        print(f"✅ CUDA Available: {cuda_available}")
        
        if cuda_available:
            print(f"✅ CUDA Version: {torch.version.cuda}")
            print(f"✅ GPU Count: {torch.cuda.device_count()}")
            
            for i in range(torch.cuda.device_count()):
                gpu_name = torch.cuda.get_device_name(i)
                print(f"✅ GPU {i}: {gpu_name}")
        else:
            print("⚠️  CUDA not available - TorchSparse will run in CPU mode only")
        
        return True
        
    except ImportError as e:
        print(f"❌ PyTorch: Import failed - {e}")
        return False

def check_torchsparse_import():
    """Check TorchSparse import."""
    print_section("TorchSparse Import")
    
    try:
        import torchsparse
        print(f"✅ TorchSparse imported successfully")
        print(f"✅ Version: {torchsparse.__version__}")
        
        # Check if backend is available
        try:
            import torchsparse.backend
            print(f"✅ Backend module loaded")
        except ImportError as e:
            print(f"❌ Backend import failed: {e}")
            return False
        
        return True
        
    except ImportError as e:
        print(f"❌ TorchSparse import failed: {e}")
        print("\nPossible solutions:")
        print("1. Install TorchSparse: pip install torchsparse")
        print("2. Use pre-built wheel from GitHub releases")
        print("3. Build from source following WINDOWS_SETUP_GUIDE.md")
        return False

def test_basic_functionality():
    """Test basic TorchSparse functionality."""
    print_section("Basic Functionality Tests")
    
    try:
        import torch
        import torchsparse
        
        # Test 1: Create sparse tensor
        print("Test 1: Creating sparse tensor...")
        coords = torch.randint(0, 10, (100, 4))
        feats = torch.randn(100, 16)
        
        sparse_tensor = torchsparse.SparseTensor(coords=coords, feats=feats)
        print(f"✅ Sparse tensor created: {sparse_tensor.shape}")
        
        # Test 2: Basic operations
        print("Test 2: Basic operations...")
        dense_shape = sparse_tensor.dense_shape
        print(f"✅ Dense shape: {dense_shape}")
        
        # Test 3: CUDA operations (if available)
        if torch.cuda.is_available():
            print("Test 3: CUDA operations...")
            coords_cuda = coords.cuda()
            feats_cuda = feats.cuda()
            sparse_tensor_cuda = torchsparse.SparseTensor(coords=coords_cuda, feats=feats_cuda)
            print(f"✅ CUDA sparse tensor created: {sparse_tensor_cuda.shape}")
        else:
            print("Test 3: Skipped (CUDA not available)")
        
        # Test 4: Convolution operation
        print("Test 4: Sparse convolution...")
        conv = torchsparse.nn.Conv3d(16, 32, kernel_size=3)
        if torch.cuda.is_available() and sparse_tensor.feats.is_cuda:
            conv = conv.cuda()
        
        output = conv(sparse_tensor)
        print(f"✅ Convolution output: {output.shape}")
        
        return True
        
    except Exception as e:
        print(f"❌ Functionality test failed: {e}")
        print(f"Error details: {traceback.format_exc()}")
        return False

def test_performance():
    """Test performance with larger tensors."""
    print_section("Performance Test")
    
    try:
        import torch
        import torchsparse
        import time
        
        # Create larger sparse tensor
        print("Creating large sparse tensor (10,000 points)...")
        coords = torch.randint(0, 50, (10000, 4))
        feats = torch.randn(10000, 64)
        
        if torch.cuda.is_available():
            coords = coords.cuda()
            feats = feats.cuda()
            device_name = "CUDA"
        else:
            device_name = "CPU"
        
        start_time = time.time()
        sparse_tensor = torchsparse.SparseTensor(coords=coords, feats=feats)
        creation_time = time.time() - start_time
        
        print(f"✅ Large tensor created on {device_name}: {sparse_tensor.shape}")
        print(f"✅ Creation time: {creation_time:.4f} seconds")
        
        # Test convolution performance
        conv = torchsparse.nn.Conv3d(64, 128, kernel_size=3)
        if torch.cuda.is_available():
            conv = conv.cuda()
        
        start_time = time.time()
        output = conv(sparse_tensor)
        conv_time = time.time() - start_time
        
        print(f"✅ Convolution completed: {output.shape}")
        print(f"✅ Convolution time: {conv_time:.4f} seconds")
        
        return True
        
    except Exception as e:
        print(f"❌ Performance test failed: {e}")
        return False

def check_dependencies():
    """Check for common dependencies."""
    print_section("Dependencies Check")
    
    dependencies = [
        ("numpy", "NumPy"),
        ("torch", "PyTorch"),
        ("torchsparse", "TorchSparse")
    ]
    
    all_good = True
    for module_name, display_name in dependencies:
        try:
            module = __import__(module_name)
            version = getattr(module, '__version__', 'Unknown')
            print(f"✅ {display_name}: {version}")
        except ImportError:
            print(f"❌ {display_name}: Not installed")
            all_good = False
    
    return all_good

def generate_report():
    """Generate a comprehensive report."""
    print_header("TorchSparse Installation Verification Report")
    
    results = {
        "System Info": check_system_info(),
        "CUDA Toolkit": check_cuda_toolkit(),
        "PyTorch": check_pytorch(),
        "Dependencies": check_dependencies(),
        "TorchSparse Import": check_torchsparse_import(),
        "Basic Functionality": False,
        "Performance Test": False
    }
    
    # Only run functionality tests if import succeeded
    if results["TorchSparse Import"]:
        results["Basic Functionality"] = test_basic_functionality()
        results["Performance Test"] = test_performance()
    
    # Print summary
    print_header("Verification Summary")
    
    passed = sum(results.values())
    total = len(results)
    
    for test_name, result in results.items():
        status = "✅ PASS" if result else "❌ FAIL"
        print(f"{test_name:.<30} {status}")
    
    print(f"\nOverall Result: {passed}/{total} tests passed")
    
    if passed == total:
        print("\n🎉 TorchSparse is properly installed and functioning!")
        print("You can now use TorchSparse in your projects.")
    else:
        print(f"\n⚠️  {total - passed} test(s) failed.")
        print("Please check the error messages above and refer to:")
        print("- WINDOWS_SETUP_GUIDE.md for installation instructions")
        print("- TROUBLESHOOTING.md for common issues")
        print("- GitHub Issues: https://github.com/Deathdadev/torchsparse/issues")
    
    return passed == total

def main():
    """Main verification function."""
    try:
        success = generate_report()
        sys.exit(0 if success else 1)
    except KeyboardInterrupt:
        print("\n\nVerification interrupted by user.")
        sys.exit(1)
    except Exception as e:
        print(f"\n\nUnexpected error during verification: {e}")
        print(f"Error details: {traceback.format_exc()}")
        sys.exit(1)

if __name__ == "__main__":
    main()
