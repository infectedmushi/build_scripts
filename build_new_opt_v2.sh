#!/bin/bash

# Improved Kernel Build Script with Error Handling
# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# ============================================================================
# Color and Formatting Setup
# ============================================================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
ENDCOLOR="\e[0m"
bold=$(tput bold)
normal=$(tput sgr0)

# ============================================================================
# Helper Functions
# ============================================================================
timestamp() {
    date +"%Y%m%d-%H%M"
}

log_info() {
    echo -e "${GREEN}${bold}[INFO]${normal} $1${ENDCOLOR}"
}

log_error() {
    echo -e "${RED}${bold}[ERROR]${normal} $1${ENDCOLOR}"
}

log_warning() {
    echo -e "${YELLOW}${bold}[WARNING]${normal} $1${ENDCOLOR}"
}

log_step() {
    echo -e "${BLUE}${bold}==>${normal} $1${ENDCOLOR}"
}

# Error handler
error_exit() {
    log_error "$1"
    exit 1
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Validate required tools
validate_requirements() {
    log_step "Validating requirements..."
    
    local required_tools=("git" "make" "clang" "zip" "patch" "curl")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command_exists "$tool"; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        error_exit "Missing required tools: ${missing_tools[*]}"
    fi
    
    log_info "All required tools found ✓"
}

# ============================================================================
# Configuration Variables
# ============================================================================
export USE_CCACHE=1
export CCACHE_DIR=/mnt/ccache/.ccache
export LLVM_CACHE_PATH=~/.cache/llvm

# Paths
CLANG_PATH="/mnt/Android/clang-22/bin"
ARM64_TOOLCHAIN="/mnt/Android/new_kernel_ksun/arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
ARM32_TOOLCHAIN="/mnt/Android/new_kernel_ksun/arm-gnu-toolchain-14.3.rel1-x86_64-arm-none-eabi/bin/arm-none-eabi-"

# Kernel specific
KERNEL_DIR="common"
CONFIG_FILE="arch/arm64/configs/gki_defconfig"
OUT_DIR="out"
RESET_COMMIT="f6787ec80"

# ============================================================================
# User Input
# ============================================================================
get_user_input() {
    log_step "Getting build configuration..."
    
    # Build identifier
    read -p "Enter the value for BUILD: " BUILD
    if [ -z "$BUILD" ]; then
        error_exit "BUILD value cannot be empty"
    fi
    log_info "Build identifier: $BUILD"
    
    export ZIP_NAME_RAW="AK3-A14-6.1.145-KSUN-$(timestamp)-$BUILD.zip"
    
    # Pixel 8a configuration
    read -p "Is the kernel for Pixel 8a? [y/n]: " PIXEL8A
    PIXEL8A=${PIXEL8A,,}  # Convert to lowercase
    
    # LTO choice
    echo "Select LTO option:"
    echo "  1) Full LTO"
    echo "  2) Thin LTO"
    echo "  3) No LTO"
    read -p "Enter choice (1-3): " lto_choice
    
    case $lto_choice in
        1) LTO_TYPE="full" ;;
        2) LTO_TYPE="thin" ;;
        3) LTO_TYPE="none" ;;
        *) error_exit "Invalid LTO choice" ;;
    esac
    
    log_info "LTO configuration: $LTO_TYPE"
}

# ============================================================================
# Repository Setup
# ============================================================================
setup_repositories() {
    log_step "Setting up repositories..."
    
    # Clean old directories
    local dirs=("susfs4ksu" "AnyKernel3-p8a" "kernel_patches")
    for dir in "${dirs[@]}"; do
        if [ -d "$dir" ]; then
            log_info "Removing old $dir directory..."
            rm -rf "$dir"
        fi
    done
    
    # Clone repositories
    log_info "Cloning susfs4ksu..."
    git clone https://gitlab.com/pershoot/susfs4ksu.git -b gki-android14-6.1-dev || \
        error_exit "Failed to clone susfs4ksu"
    
    log_info "Cloning AnyKernel3-p8a..."
    git clone https://github.com/deepongi-labs/AnyKernel3-p8a -b gki-2.0 || \
        error_exit "Failed to clone AnyKernel3-p8a"
    
    log_info "Cloning kernel_patches..."
    git clone https://github.com/infectedmushi/kernel_patches -b main || \
        error_exit "Failed to clone kernel_patches"
    
    log_info "Repositories cloned successfully ✓"
}

# ============================================================================
# Compiler Setup
# ============================================================================
setup_compiler() {
    log_step "Setting up compiler..."
    
    if [ ! -d "$CLANG_PATH" ]; then
        error_exit "Clang path not found: $CLANG_PATH"
    fi
    
    export PATH="$CLANG_PATH:$PATH"
    log_info "Clang path added: $CLANG_PATH ✓"
    
    # Verify clang is accessible
    if ! command_exists clang; then
        error_exit "Clang not found in PATH"
    fi
    
    clang --version | head -n1
}

# ============================================================================
# Kernel Source Preparation
# ============================================================================
prepare_kernel_source() {
    log_step "Preparing kernel source..."
    
    if [ ! -d "$KERNEL_DIR" ]; then
        error_exit "Kernel directory not found: $KERNEL_DIR"
    fi
    
    cd "$KERNEL_DIR" || error_exit "Failed to enter kernel directory"
    
    # Handle KernelSU-Next directory
    local ksu_dir="KernelSU-Next"
    if [ -d "$ksu_dir" ]; then
        log_info "KernelSU-Next directory exists, removing..."
        rm -rf "$ksu_dir"
    fi
    
    # Clean and reset
    log_info "Cleaning git repository..."
    git clean -fdx || log_warning "Git clean failed (might be expected)"
    
    log_info "Resetting to commit $RESET_COMMIT..."
    git reset --hard "$RESET_COMMIT" || error_exit "Failed to reset to commit"
    
    log_info "Kernel source prepared ✓"
}

# ============================================================================
# Pixel 8a Configuration
# ============================================================================
configure_pixel8a() {
    if [[ ! "$PIXEL8A" =~ ^[yY]$ ]]; then
        log_info "Skipping Pixel 8a specific configuration"
        return 0
    fi
    
    log_step "Configuring for Pixel 8a (Tensor G3)..."
    
    local config="$CONFIG_FILE"
    
    # Function to add config if not present
    add_config() {
        local cfg="$1"
        if ! grep -q "^${cfg}$" "$config" 2>/dev/null; then
            echo "$cfg" >> "$config"
        fi
    }
    
    # Tensor G3 CPU cores
    add_config "CONFIG_ARM64_CORTEX_X3=y"
    add_config "CONFIG_ARM64_CORTEX_A715=y"
    add_config "CONFIG_ARM64_CORTEX_A510=y"
    
    # Memory and address space
    add_config "CONFIG_ARM64_VA_BITS=48"
    add_config "CONFIG_ARM64_PA_BITS=48"
    add_config "CONFIG_ARM64_TAGGED_ADDR_ABI=y"
    add_config "CONFIG_ARM64_SVE=y"
    add_config "CONFIG_ARM64_BTI=y"
    add_config "CONFIG_ARM64_PTR_AUTH=y"
    
    # Scheduler optimizations
    add_config "CONFIG_SCHED_MC=y"
    add_config "CONFIG_SCHED_CORE=y"
    add_config "CONFIG_ENERGY_MODEL=y"
    add_config "CONFIG_UCLAMP_TASK=y"
    add_config "CONFIG_UCLAMP_TASK_GROUP=y"
    add_config "CONFIG_SCHEDUTIL=y"
    
    # CPU Frequency
    add_config "CONFIG_CPU_FREQ=y"
    add_config "CONFIG_CPUFREQ_DT=y"
    add_config "CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y"
    add_config "CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y"
    add_config "CONFIG_OPP=y"
    
    # CPU Idle
    add_config "CONFIG_CPU_IDLE=y"
    add_config "CONFIG_ARM_PSCI_CPUIDLE=y"
    
    # Thermal management
    add_config "CONFIG_THERMAL=y"
    add_config "CONFIG_CPU_THERMAL=y"
    add_config "CONFIG_DEVFREQ_THERMAL=y"
    add_config "CONFIG_THERMAL_GOV_POWER_ALLOCATOR=y"
    add_config "CONFIG_THERMAL_GOV_STEP_WISE=y"
    add_config "CONFIG_THERMAL_GOV_FAIR_SHARE=y"
    add_config "CONFIG_THERMAL_EMULATION=y"
    add_config "CONFIG_THERMAL_WRITABLE_TRIPS=y"
    add_config "CONFIG_POWER_CAP=y"
    
    # Additional optimizations
    add_config "CONFIG_PERF_EVENTS=y"
    add_config "CONFIG_ARM64_SME=y"
    add_config "CONFIG_NUMA_BALANCING=y"
    add_config "CONFIG_CMA=y"
    add_config "CONFIG_CMA_AREAS=7"
    
    # Network optimizations
    add_config "CONFIG_TCP_CONG_ADVANCED=y"
    add_config "CONFIG_TCP_CONG_CUBIC=y"
    add_config "CONFIG_NET_SCH_FQ_CODEL=y"
    add_config "CONFIG_DEFAULT_FQ_CODEL=y"
    add_config "CONFIG_NET_SCH_CAKE=y"
    add_config "CONFIG_DEFAULT_CAKE=y"
    add_config "CONFIG_DEFAULT_TCP_CONG=\"bbr\""
    
    # F2FS filesystem
    add_config "CONFIG_F2FS_FS=y"
    add_config "CONFIG_F2FS_FS_XATTR=y"
    add_config "CONFIG_F2FS_FS_POSIX_ACL=y"
    add_config "CONFIG_F2FS_FS_SECURITY=y"
    add_config "CONFIG_F2FS_FS_COMPRESSION=y"
    
    log_info "Pixel 8a configuration complete ✓"
}

# ============================================================================
# LTO Configuration
# ============================================================================
configure_lto() {
    log_step "Configuring LTO ($LTO_TYPE)..."
    
    local config="$CONFIG_FILE"
    
    case $LTO_TYPE in
        full)
            echo "CONFIG_LTO_CLANG_FULL=y" >> "$config"
            ;;
        thin)
            echo "CONFIG_LTO_CLANG_THIN=y" >> "$config"
            ;;
        none)
            echo "CONFIG_LTO_NONE=y" >> "$config"
            ;;
    esac
    
    log_info "LTO configured ✓"
}

# ============================================================================
# KernelSU-Next Installation
# ============================================================================
install_kernelsu() {
    log_step "Installing KernelSU-Next..."
    
    curl -LSs "https://raw.githubusercontent.com/infectedmushi/KernelSU-Next/next-susfs/kernel/setup.sh" | bash -s next-susfs || \
        error_exit "Failed to install KernelSU-Next"
    
    log_info "KernelSU-Next installed ✓"
}

# ============================================================================
# SUSFS Patches
# ============================================================================
apply_susfs_patches() {
    log_step "Applying SUSFS patches..."
    
    # Copy patches
    cp -v ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch ./ || \
        error_exit "Failed to copy SUSFS patch 50"
    cp -v ../susfs4ksu/kernel_patches/60_scope-minimized_manual_hooks.patch ./ || \
        error_exit "Failed to copy SUSFS patch 60"
    
    # Copy filesystem patches
    cp -v ../susfs4ksu/kernel_patches/fs/* ./fs/ || \
        error_exit "Failed to copy fs patches"
    cp -v ../susfs4ksu/kernel_patches/include/linux/* ./include/linux/ || \
        error_exit "Failed to copy include patches"
    
    # Apply patches (--forward allows skipping already applied patches)
    log_info "Applying patch 50..."
    patch -p1 --forward < 50_add_susfs_in_gki-android14-6.1.patch || \
        log_warning "Patch 50 may have been already applied"
    
    log_info "Applying patch 60..."
    patch -p1 --forward < 60_scope-minimized_manual_hooks.patch || \
        log_warning "Patch 60 may have been already applied"
    
    log_info "SUSFS patches applied ✓"
}

# ============================================================================
# Additional Patches
# ============================================================================
apply_additional_patches() {
    log_step "Applying additional patches..."
    
    # Check if fix patch exists
    if [ -f "../fix-clidr-uninitialized.patch" ]; then
        log_info "Applying fix-clidr-uninitialized patch..."
        cp -v ../fix-clidr-uninitialized.patch ./ || \
            error_exit "Failed to copy fix patch"
        patch -p1 --forward < fix-clidr-uninitialized.patch || \
            log_warning "Fix patch may have been already applied"
    else
        log_warning "fix-clidr-uninitialized.patch not found, skipping..."
    fi
    
    log_info "Additional patches applied ✓"
}

# ============================================================================
# Kernel Configuration
# ============================================================================
configure_kernel() {
    log_step "Configuring kernel settings..."
    
    local config="$CONFIG_FILE"
    
    # Function to add unique config
    add_config() {
        local cfg="$1"
        if ! grep -q "^${cfg}$" "$config" 2>/dev/null; then
            echo "$cfg" >> "$config"
        fi
    }
    
    # Remove ABI exports
    log_info "Removing ABI exports..."
    rm -v android/abi_gki_protected_exports_* 2>/dev/null || \
        log_warning "No ABI exports to remove"
    
    # Base configuration
    add_config "CONFIG_LOCALVERSION_AUTO=n"
    add_config "CONFIG_LOCALVERSION=\"-deepongi\""
    
    # KernelSU configuration
    add_config "CONFIG_KSU=y"
    add_config "CONFIG_KSU_KPROBES_HOOK=n"
    add_config "CONFIG_KSU_SUSFS=y"
    add_config "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y"
    add_config "CONFIG_KSU_SUSFS_SUS_PATH=y"
    add_config "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
    add_config "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y"
    add_config "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y"
    add_config "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
    add_config "CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n"
    add_config "CONFIG_KSU_SUSFS_TRY_UMOUNT=y"
    add_config "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y"
    add_config "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
    add_config "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
    add_config "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
    add_config "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
    add_config "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
    add_config "CONFIG_KSU_SUSFS_SUS_SU=n"
    add_config "CONFIG_KSU_SWITCH_MANAGER=y"
    
    # Filesystem configuration
    add_config "CONFIG_TMPFS_XATTR=y"
    add_config "CONFIG_TMPFS_POSIX_ACL=y"
    
    # Network configuration
    add_config "CONFIG_IP_NF_TARGET_TTL=y"
    add_config "CONFIG_IP6_NF_TARGET_HL=y"
    add_config "CONFIG_IP6_NF_MATCH_HL=y"
    add_config "CONFIG_TCP_CONG_ADVANCED=y"
    add_config "CONFIG_TCP_CONG_BBR=y"
    add_config "CONFIG_NET_SCH_FQ=y"
    add_config "CONFIG_TCP_CONG_BIC=n"
    add_config "CONFIG_TCP_CONG_WESTWOOD=n"
    add_config "CONFIG_TCP_CONG_HTCP=n"
    
    # Compiler optimizations
    add_config "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y"
    add_config "CONFIG_CCACHE=y"
    
    log_info "Kernel configuration complete ✓"
}

# ============================================================================
# Build Preparation
# ============================================================================
prepare_build() {
    log_step "Preparing for build..."
    
    # Remove -dirty tag
    log_info "Removing -dirty tag from version string..."
    sed -i '/# Check for uncommitted changes\./,/fi/d' ./scripts/setlocalversion || \
        log_warning "Could not modify setlocalversion"
    
    # Skip defconfig check
    log_info "Disabling defconfig check..."
    sed -i '2s/check_defconfig//' ./build.config.gki 2>/dev/null || \
        log_warning "Could not modify build.config.gki"
    
    # Handle out directory
    if [ -d "$OUT_DIR" ]; then
        log_warning "Output directory exists"
        read -p "Delete 'out' folder? (y/n): " REPLY
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            rm -rf "$OUT_DIR"
            log_info "Output directory removed"
        else
            log_info "Keeping existing output directory"
        fi
    fi
    
    log_info "Build preparation complete ✓"
}

# ============================================================================
# Kernel Compilation
# ============================================================================
compile_kernel() {
    log_step "Compiling kernel..."
    
    local start_time=$(date +%s)
    
    # Compilation command with error handling
    if ! time make -j$(nproc) \
        LLVM_IAS=1 \
        LLVM=1 \
        ARCH=arm64 \
        CLANG_TRIPLE=aarch64-linux-gnu- \
        CROSS_COMPILE_COMPAT="$ARM32_TOOLCHAIN" \
        CROSS_COMPILE="$ARM64_TOOLCHAIN" \
        CC="ccache clang" \
        LD=ld.lld \
        HOSTLD=ld.lld \
        O="$OUT_DIR" \
        gki_defconfig all; then
        error_exit "Kernel compilation failed"
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "Kernel compiled successfully in ${duration}s ✓"
    
    # Verify kernel image exists
    if [ ! -f "$OUT_DIR/arch/arm64/boot/Image" ]; then
        error_exit "Kernel Image not found after compilation"
    fi
}

# ============================================================================
# Packaging
# ============================================================================
package_kernel() {
    log_step "Packaging kernel..."
    
    cd .. || error_exit "Failed to return to parent directory"
    
    local kernel_image="$KERNEL_DIR/$OUT_DIR/arch/arm64/boot/Image"
    local anykernel_dir="AnyKernel3-p8a"
    local builds_dir="builds/6.1.145"
    
    # Verify kernel image exists
    if [ ! -f "$kernel_image" ]; then
        error_exit "Kernel image not found: $kernel_image"
    fi
    
    # Copy kernel to AnyKernel3
    log_info "Copying kernel image to AnyKernel3..."
    cp -v "$kernel_image" "$anykernel_dir/" || \
        error_exit "Failed to copy kernel image"
    
    # Enter AnyKernel directory
    cd "$anykernel_dir" || error_exit "Failed to enter AnyKernel directory"
    
    # Remove .git to reduce size
    rm -rf .git
    
    # Create zip
    log_info "Creating flashable zip: $ZIP_NAME_RAW"
    if ! zip -r "$ZIP_NAME_RAW" ./*; then
        error_exit "Failed to create zip file"
    fi
    
    # Clean up
    rm -f Image
    
    # Create builds directory if it doesn't exist
    mkdir -p "../$builds_dir"
    
    # Move zip to builds directory
    log_info "Moving zip to builds directory..."
    mv "$ZIP_NAME_RAW" "../$builds_dir/" || \
        error_exit "Failed to move zip file"
    
    cd .. || true
    
    log_info "Kernel packaged successfully ✓"
    log_info "Output: $builds_dir/$ZIP_NAME_RAW"
}

# ============================================================================
# Main Execution
# ============================================================================
main() {
    echo ""
    log_step "Starting Kernel Build Process"
    echo ""
    
    # Validate requirements
    validate_requirements
    
    # Get user configuration
    get_user_input
    
    # Setup phase
    setup_repositories
    setup_compiler
    
    # Kernel preparation
    prepare_kernel_source
    
    # Configuration
    configure_pixel8a
    configure_lto
    
    # KernelSU and patches
    install_kernelsu
    apply_susfs_patches
    apply_additional_patches
    
    # Configure kernel
    configure_kernel
    
    # Build
    prepare_build
    compile_kernel
    
    # Package
    package_kernel
    
    echo ""
    log_info "====================================="
    log_info "Build completed successfully! 🎉"
    log_info "====================================="
    echo ""
}

# Run main function
main "$@"
