#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, pipe failures

#=============================================================================
# SukiSU Kernel Build Script - Enhanced Version
#=============================================================================

# Color definitions
readonly RED="\e[31m"
readonly GREEN="\e[32m"
readonly YELLOW="\e[33m"
readonly BLUE="\e[34m"
readonly ENDCOLOR="\e[0m"
readonly BOLD=$(tput bold)
readonly NORMAL=$(tput sgr0)

# Build paths
readonly CCACHE_DIR_PATH="/mnt/ccache/.ccache"
readonly LLVM_CACHE_PATH_DIR="$HOME/.cache/llvm"
readonly CLANG_PATH="/mnt/Android/clang-22/bin"
readonly ARM_COMPAT_PATH="/mnt/Android/new_kernel_ksun/arm-gnu-toolchain-14.3.rel1-x86_64-arm-none-eabi/bin"
readonly ARM64_PATH="/mnt/Android/new_kernel_ksun/arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu/bin"

# Export environment
export USE_CCACHE=1
export CCACHE_DIR="$CCACHE_DIR_PATH"
export LLVM_CACHE_PATH="$LLVM_CACHE_PATH_DIR"

#=============================================================================
# Helper Functions
#=============================================================================

timestamp() {
    date +"%Y%m%d-%H%M"
}

log_info() {
    echo -e "${BLUE}${BOLD}[INFO]${NORMAL}${ENDCOLOR} $*"
}

log_success() {
    echo -e "${GREEN}${BOLD}[SUCCESS]${NORMAL}${ENDCOLOR} $*"
}

log_error() {
    echo -e "${RED}${BOLD}[ERROR]${NORMAL}${ENDCOLOR} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}${BOLD}[WARNING]${NORMAL}${ENDCOLOR} $*"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Required command '$1' not found"
        exit 1
    fi
}

cleanup_dirs() {
    log_info "Cleaning up existing directories..."
    rm -rf susfs4ksu AnyKernel3-p8a SukiSU_patch
    log_success "Cleanup completed"
}

clone_repos() {
    log_info "Cloning required repositories..."
    
    git clone https://gitlab.com/pershoot/susfs4ksu.git -b gki-android14-6.1-dev &
    git clone https://github.com/deepongi-labs/AnyKernel3-p8a -b sukisu &
    git clone git@github.com:SukiSU-Ultra/SukiSU_patch.git &
    
    wait
    log_success "All repositories cloned"
}

setup_kernel_dir() {
    log_info "Setting up kernel directory..."
    cd common || exit 1
    
    if [ -d "KernelSU" ]; then
        log_warning "KernelSU directory exists, cleaning..."
        rm -rf KernelSU
    fi
    
    git reset --hard 86676b1f0
    git clean -fdx
    log_success "Kernel directory ready"
}

configure_pixel8a() {
    local config_file="arch/arm64/configs/gki_defconfig"
    
    log_info "Configuring for Pixel 8a (Tensor G3)..."
    
    # Pixel 8a specific optimizations
    local -a opts=(
        # CPU Architecture - Tensor G3 cores
        "CONFIG_ARM64_CORTEX_X3=y"
        "CONFIG_ARM64_CORTEX_A715=y"
        "CONFIG_ARM64_CORTEX_A510=y"
        
        # Memory and address space
        "CONFIG_ARM64_VA_BITS=48"
        "CONFIG_ARM64_PA_BITS=48"
        "CONFIG_ARM64_TAGGED_ADDR_ABI=y"
        
        # Advanced CPU features
        "CONFIG_ARM64_SVE=y"
        "CONFIG_ARM64_SME=y"
        "CONFIG_ARM64_BTI=y"
        "CONFIG_ARM64_PTR_AUTH=y"
        
        # Scheduler optimizations
        "CONFIG_SCHED_MC=y"
        "CONFIG_SCHED_CORE=y"
        "CONFIG_ENERGY_MODEL=y"
        "CONFIG_UCLAMP_TASK=y"
        "CONFIG_UCLAMP_TASK_GROUP=y"
        "CONFIG_SCHEDUTIL=y"
        "CONFIG_NUMA_BALANCING=y"
        
        # CPU frequency and power
        "CONFIG_CPU_FREQ=y"
        "CONFIG_CPUFREQ_DT=y"
        "CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y"
        "CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y"
        "CONFIG_OPP=y"
        "CONFIG_CPU_IDLE=y"
        "CONFIG_ARM_PSCI_CPUIDLE=y"
        
        # Thermal management
        "CONFIG_THERMAL=y"
        "CONFIG_CPU_THERMAL=y"
        "CONFIG_DEVFREQ_THERMAL=y"
        "CONFIG_THERMAL_GOV_POWER_ALLOCATOR=y"
        "CONFIG_THERMAL_GOV_STEP_WISE=y"
        "CONFIG_THERMAL_GOV_FAIR_SHARE=y"
        "CONFIG_THERMAL_EMULATION=y"
        "CONFIG_THERMAL_WRITABLE_TRIPS=y"
        "CONFIG_POWER_CAP=y"
        
        # Networking optimizations
        "CONFIG_TCP_CONG_ADVANCED=y"
        "CONFIG_TCP_CONG_CUBIC=y"
        "CONFIG_DEFAULT_TCP_CONG=\"bbr\""
        "CONFIG_NET_SCH_FQ_CODEL=y"
        "CONFIG_DEFAULT_FQ_CODEL=y"
        "CONFIG_NET_SCH_CAKE=y"
        "CONFIG_DEFAULT_CAKE=y"
        
        # Filesystem
        "CONFIG_F2FS_FS=y"
        "CONFIG_F2FS_FS_XATTR=y"
        "CONFIG_F2FS_FS_POSIX_ACL=y"
        "CONFIG_F2FS_FS_SECURITY=y"
        "CONFIG_F2FS_FS_COMPRESSION=y"
        
        # Memory management
        "CONFIG_CMA=y"
        "CONFIG_CMA_AREAS=7"
        "CONFIG_PERF_EVENTS=y"
    )
    
    for opt in "${opts[@]}"; do
        if ! grep -q "$opt" "$config_file"; then
            echo "$opt" >> "$config_file"
        fi
    done
    
    log_success "Pixel 8a configuration applied"
}

configure_lto() {
    local config_file="arch/arm64/configs/gki_defconfig"
    
    read -p "Select LTO mode (full/thin/none): " lto_choice
    
    case "$lto_choice" in
        full)
            echo "CONFIG_LTO_CLANG_FULL=y" >> "$config_file"
            log_success "LTO Full enabled"
            ;;
        thin)
            echo "CONFIG_LTO_CLANG_THIN=y" >> "$config_file"
            log_success "LTO Thin enabled"
            ;;
        none)
            echo "CONFIG_LTO=n" >> "$config_file"
            log_success "LTO disabled"
            ;;
        *)
            log_error "Invalid LTO choice: $lto_choice"
            exit 1
            ;;
    esac
}

setup_sukisu() {
    log_info "Setting up SukiSU-Ultra..."
    curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/susfs-main/kernel/setup.sh" | bash -s susfs-main
    log_success "SukiSU-Ultra installed"
}

apply_patches() {
    log_info "Applying SUSFS patches..."
    cp -v ../susfs4ksu/kernel_patches/fs/* ./fs/
    cp -v ../susfs4ksu/kernel_patches/include/linux/* ./include/linux/
    patch -p1 --forward < ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch
    
    log_info "Applying SukiSU patches..."
    patch -p1 < ../SukiSU_patch/hooks/scope_min_manual_hooks_v1.6.patch
    patch -p1 < ../SukiSU_patch/69_hide_stuff.patch
    
    log_info "Applying bug fixes..."
    patch -p1 --forward < ../fix-clidr-uninitialized.patch
    
    log_success "All patches applied"
}

configure_ksu() {
    local config_file="arch/arm64/configs/gki_defconfig"
    
    log_info "Configuring KernelSU settings..."
    
    cat >> "$config_file" << 'EOF'
# Kernel identification
CONFIG_LOCALVERSION_AUTO=n
CONFIG_LOCALVERSION="-deepongi"

# KernelSU Core
CONFIG_KSU=y
CONFIG_KSU_DEBUG=n
CONFIG_KSU_MANUAL_HOOK=y

# SUSFS Configuration
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_SU=n
CONFIG_KSU_SUSFS_SUS_MAP=y

# Filesystem support
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y

# Network filter support
CONFIG_IP_NF_TARGET_TTL=y
CONFIG_IP6_NF_TARGET_HL=y
CONFIG_IP6_NF_MATCH_HL=y

# TCP congestion control
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_NET_SCH_FQ=y
CONFIG_TCP_CONG_BIC=n
CONFIG_TCP_CONG_WESTWOOD=n
CONFIG_TCP_CONG_HTCP=n

# Compiler optimizations
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
CONFIG_CC_FLAGS="-O3 -flto -ffunction-sections -fdata-sections"
CONFIG_CCACHE=y
EOF
    
    log_success "KernelSU configuration complete"
}

prepare_build() {
    log_info "Preparing build environment..."
    
    # Remove exports
    rm -v android/abi_gki_protected_exports_* 2>/dev/null || true
    
    # Clean -dirty tag
    sed -i '/# Check for uncommitted changes\./,/fi/d' ./scripts/setlocalversion
    sed -i '2s/check_defconfig//' ./build.config.gki
    
    # Ask about cleaning output directory
    if [ -d "out" ]; then
        log_warning "Output directory 'out' exists"
        read -p "Clean output directory? This will increase build time. [y/N]: " clean_out
        if [[ "$clean_out" =~ ^[yY]$ ]]; then
            log_info "Cleaning output directory..."
            rm -rf out
            make clean &>/dev/null || true
            log_success "Output directory cleaned"
        else
            log_info "Keeping existing output directory for incremental build"
        fi
    else
        log_info "No existing output directory found"
    fi
    
    log_success "Build environment ready"
}

build_kernel() {
    log_info "Starting kernel compilation..."
    
    export PATH="$CLANG_PATH:$PATH"
    
    local start_time=$(date +%s)
    
    time make -j"$(nproc)" \
        LLVM_IAS=1 \
        LLVM=1 \
        ARCH=arm64 \
        CLANG_TRIPLE=aarch64-linux-gnu- \
        CROSS_COMPILE_COMPAT="$ARM_COMPAT_PATH/arm-none-eabi-" \
        CROSS_COMPILE="$ARM64_PATH/aarch64-none-linux-gnu-" \
        CC="ccache clang" \
        LD=ld.lld \
        HOSTLD=ld.lld \
        O=out \
        gki_defconfig all
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_success "Kernel compiled in ${duration} seconds"
}

package_kernel() {
    local zip_name="$1"
    
    log_info "Packaging kernel..."
    
    cd ..
    cp -v ./common/out/arch/arm64/boot/Image ./AnyKernel3-p8a
    cd ./AnyKernel3-p8a
    
    rm -rf .git
    zip -r "$zip_name" ./* &>/dev/null
    
    rm -rf Image
    mkdir -p ../builds/6.1.155
    mv "$zip_name" ../builds/6.1.155/
    
    log_success "Kernel packaged: $zip_name"
}

#=============================================================================
# Main Script
#=============================================================================

main() {
    log_info "Starting SukiSU Kernel Build Process"
    
    # Check dependencies
    check_command git
    check_command make
    check_command clang
    check_command zip
    check_command curl
    
    # Get build identifier
    read -p "Enter BUILD identifier: " BUILD
    export ZIP_NAME_RAW="AK3-A14-6.1.155-SukiSU-$(timestamp)-${BUILD}.zip"
    log_info "Build: $ZIP_NAME_RAW"
    
    # Build process
    cleanup_dirs
    clone_repos
    setup_kernel_dir
    
    # Pixel 8a configuration
    read -p "Configure for Pixel 8a? [y/N]: " pixel8a
    if [[ "$pixel8a" =~ ^[yY]$ ]]; then
        configure_pixel8a
    fi
    
    configure_lto
    setup_sukisu
    apply_patches
    configure_ksu
    prepare_build
    build_kernel
    package_kernel "$ZIP_NAME_RAW"
    
    log_success "Build completed successfully!"
    log_info "Output: builds/6.1.155/$ZIP_NAME_RAW"
}

# Run main function
main "$@"
