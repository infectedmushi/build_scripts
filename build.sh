#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipes fail if any command in the pipe fails.
set -o pipefail

## -----------------------------------------------------------------------------
## CONFIGURATION - EDIT THESE VALUES
## -----------------------------------------------------------------------------

# Kernel and build details
export KERNEL_VERSION="6.1.145"
export BUILD_USER="deepongi" # Your name/handle for the build version

# Toolchain Paths (MUST be set correctly)
export CLANG_PATH="/mnt/Android/clang-22/bin" # e.g., /home/user/proton-clang/bin
export CROSS_COMPILE_AARCH64_PATH="/mnt/Android/new_kernel_ksun/arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu/bin" # e.g., /home/user/aarch64-toolchain/bin
export CROSS_COMPILE_ARM_PATH="/mnt/Android/new_kernel_ksun/arm-gnu-toolchain-14.3.rel1-x86_64-arm-none-eabi/bin"       # e.g., /home/user/arm-toolchain/bin

# Source Repositories
ANYKERNEL_REPO_URL="https://github.com/deepongi-labs/AnyKernel3-p8a"
ANYKERNEL_REPO_BRANCH="gki-2.0"
SUSFS_REPO_URL="https://gitlab.com/pershoot/susfs4ksu.git"
SUSFS_REPO_BRANCH="gki-android14-6.1-dev"
export PATCHES_REPO_URL="https://github.com/infectedmushi/kernel_patches"
export PATCHES_REPO_BRANCH="main"
KERNEL_SOURCE_DIR="common"

## -----------------------------------------------------------------------------
## SCRIPT LOGIC - DO NOT EDIT BELOW THIS LINE
## -----------------------------------------------------------------------------

# Script Colors and Formatting
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
ENDCOLOR="\e[0m"
BOLD=$(tput bold)
NORMAL=$(tput sgr0)

# Start Timer
START_TIME=$(date +%s)

# --- Helper Functions ---
log_step() {
    echo -e "\n${BLUE}${BOLD}==> $1${NORMAL}${ENDCOLOR}"
}

log_info() {
    echo -e "${GREEN} -> $1${ENDCOLOR}"
}

log_warn() {
    echo -e "${YELLOW} -> WARNING: $1${ENDCOLOR}"
}

log_error() {
    echo -e "${RED}${BOLD} -> ERROR: $1${NORMAL}${ENDCOLOR}" >&2
    exit 1
}

timestamp() {
    date +"%Y%m%d-%H%M"
}

# --- Main Functions ---

check_dependencies() {
    log_step "Checking for required tools..."
    local missing_tools=0
    for tool in git clang curl patch zip ccache tput nproc; do
        if ! command -v "$tool" &> /dev/null; then
            log_warn "Tool '$tool' is not installed."
            missing_tools=1
        fi
    done
    [ "$missing_tools" -eq 1 ] && log_error "Please install the missing tools to continue."
    log_info "All required tools are present."
}

check_toolchain_paths() {
    log_step "Checking toolchain paths..."
    [ ! -d "$CLANG_PATH" ] && log_error "Clang path not found: $CLANG_PATH"
    [ ! -d "$CROSS_COMPILE_AARCH64_PATH" ] && log_error "AARCH64 toolchain not found: $CROSS_COMPILE_AARCH64_PATH"
    [ ! -d "$CROSS_COMPILE_ARM_PATH" ] && log_error "ARM toolchain not found: $CROSS_COMPILE_ARM_PATH"
    log_info "Toolchain paths are valid."
}

setup_environment() {
    log_step "Setting up build environment..."
    export USE_CCACHE=1
    export CCACHE_DIR="${CCACHE_DIR:-/mnt/ccache/.ccache}"
    mkdir -p "$CCACHE_DIR"
    export LLVM_CACHE_PATH="${LLVM_CACHE_PATH:-$HOME/.cache/llvm}"
    mkdir -p "$LLVM_CACHE_PATH"
    export PATH="$CLANG_PATH:$PATH"
    log_info "CCACHE enabled at: $CCACHE_DIR"
    
    # Clean up previous build artifacts
    rm -rf susfs4ksu AnyKernel3-p8a kernel_patches
    log_info "Cleaned up old repository directories."
}

clone_repositories() {
    log_step "Cloning source repositories..."
    git clone "$SUSFS_REPO_URL" -b "$SUSFS_REPO_BRANCH"
    git clone "$ANYKERNEL_REPO_URL" -b "$ANYKERNEL_REPO_BRANCH"
    git clone "$PATCHES_REPO_URL" -b "$PATCHES_REPO_BRANCH"
    [ ! -d "$KERNEL_SOURCE_DIR" ] && log_error "Kernel source directory '$KERNEL_SOURCE_DIR' not found!"
    log_info "Repositories cloned successfully."
}

prepare_kernel_source() {
    log_step "Preparing kernel source tree..."
    cd "$KERNEL_SOURCE_DIR"

    log_info "Resetting kernel source to a clean state..."
    rm -rf KernelSU-Next
    git reset --hard 98a7b989a # Known clean commit
    git clean -fdx
    
    cd ..
    log_info "Kernel source is clean and ready."
}

configure_kernel() {
    log_step "Configuring kernel..."
    cd "$KERNEL_SOURCE_DIR"
    
    local CONFIG_FILE="arch/arm64/configs/gki_defconfig"

    # Pixel 8a specific optimizations
    read -rp "Is this kernel for the Pixel 8a? [y/N]: " is_p8a
    if [[ "$is_p8a" =~ ^[yY]$ ]]; then
        log_info "Applying full Pixel 8a (Tensor G3) configurations for hardware support..."
        # This block contains ALL the necessary hardware configs from your working script.
        cat <<EOF | tee -a "$CONFIG_FILE" > /dev/null
# Tensor G3 CPU Cores
CONFIG_ARM64_CORTEX_X3=y
CONFIG_ARM64_CORTEX_A715=y
CONFIG_ARM64_CORTEX_A510=y
# Memory and address space
CONFIG_ARM64_VA_BITS=48
CONFIG_ARM64_PA_BITS=48
CONFIG_ARM64_TAGGED_ADDR_ABI=y
CONFIG_ARM64_SVE=y
CONFIG_ARM64_BTI=y
CONFIG_ARM64_PTR_AUTH=y
# Scheduler optimizations
CONFIG_SCHED_MC=y
CONFIG_SCHED_CORE=y
CONFIG_ENERGY_MODEL=y
CONFIG_UCLAMP_TASK=y
CONFIG_UCLAMP_TASK_GROUP=y
CONFIG_SCHEDUTIL=y
# CPU Frequency
CONFIG_CPU_FREQ=y
CONFIG_CPUFREQ_DT=y
CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y
CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y
CONFIG_OPP=y
# CPU Idle
CONFIG_CPU_IDLE=y
CONFIG_ARM_PSCI_CPUIDLE=y
# Thermal management
CONFIG_THERMAL=y
CONFIG_CPU_THERMAL=y
CONFIG_DEVFREQ_THERMAL=y
CONFIG_THERMAL_GOV_POWER_ALLOCATOR=y
CONFIG_THERMAL_GOV_STEP_WISE=y
CONFIG_THERMAL_GOV_FAIR_SHARE=y
CONFIG_THERMAL_EMULATION=y
CONFIG_THERMAL_WRITABLE_TRIPS=y
CONFIG_POWER_CAP=y
# Additional optimizations
CONFIG_PERF_EVENTS=y
CONFIG_ARM64_SME=y
CONFIG_NUMA_BALANCING=y
CONFIG_CMA=y
CONFIG_CMA_AREAS=7
EOF
    fi

    # LTO Configuration
    while true; do
        read -rp "Select LTO mode (full/thin/none) [thin]: " lto_choice
        lto_choice=${lto_choice:-thin} # Default to 'thin'
        case "$lto_choice" in
            full) echo "CONFIG_LTO_CLANG_FULL=y" >> "$CONFIG_FILE"; break ;;
            thin) echo "CONFIG_LTO_CLANG_THIN=y" >> "$CONFIG_FILE"; break ;;
            none) echo "CONFIG_LTO=n" >> "$CONFIG_FILE"; break ;;
            *) log_warn "Invalid choice. Please enter 'full', 'thin', or 'none'." ;;
        esac
    done
    log_info "LTO mode set to '$lto_choice'."

    # KernelSU, SuSFS, Networking & Performance Configuration
    log_info "Adding full KernelSU, networking, and performance configurations..."
    # This block now contains ALL the feature configs from your original working script.
    cat <<EOF | tee -a "$CONFIG_FILE" > /dev/null
CONFIG_LOCALVERSION_AUTO=n
CONFIG_LOCALVERSION="-$BUILD_USER"
CONFIG_KSU=y
CONFIG_KSU_KPROBES_HOOK=n
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_SU=n
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_IP_NF_TARGET_TTL=y
CONFIG_IP6_NF_TARGET_HL=y
CONFIG_IP6_NF_MATCH_HL=y
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_NET_SCH_FQ=y
CONFIG_TCP_CONG_BIC=n
CONFIG_TCP_CONG_WESTWOOD=n
CONFIG_TCP_CONG_HTCP=n
CONFIG_KSU_SWITCH_MANAGER=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
CONFIG_CC_FLAGS="-O3 -flto -ffunction-sections -fdata-sections"
CONFIG_CCACHE=y
EOF
    cd ..
}

apply_patches() {
    log_step "Applying custom patches..."
    cd "$KERNEL_SOURCE_DIR"

    # KernelSU Integration
    log_info "Integrating KernelSU-Next..."
    curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next/kernel/setup.sh" | bash -s next

    # SuSFS patches
    log_info "Applying SuSFS patches to the kernel..."
    patch -p1 < ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch
    patch -p1 < ../susfs4ksu/kernel_patches/60_scope-minimized_manual_hooks.patch
    cp -v ../susfs4ksu/kernel_patches/fs/* ./fs/
    cp -v ../susfs4ksu/kernel_patches/include/linux/* ./include/linux/

    # Additional hide patches (Check if file exists first)
    local hide_patch_file="../kernel_patches/69_hide_stuff.patch"
    if [ -f "$hide_patch_file" ]; then
        log_info "Applying additional hide patches..."
        patch -p1 < "$hide_patch_file"
    else
        log_warn "Hide patch not found, skipping. (Is 'kernel_patches' directory empty?)"
    fi
    
    # Apply Clang 22 compatibility patch from its new location
    local clidr_patch_file="../kernel_patches/fix-clidr-uninitialized.patch"
    if [ -f "$clidr_patch_file" ]; then
        log_info "Applying Clang 22 compatibility patch (fix-clidr-uninitialized.patch)..."
        patch -p1 < "$clidr_patch_file"
    else
        log_warn "Clang 22 compatibility patch not found, skipping."
        log_warn "This may cause build errors with Clang 22 or newer."
    fi
    
    # SuSFS integration with KernelSU
    log_info "Attempting to patch KernelSU for SuSFS integration..."
    (
        cd KernelSU-Next

        # --- MOVED & ADDED HERE ---
        log_info "Applying KSU managers patch..."
        curl -Ls https://raw.githubusercontent.com/infectedmushi/kernel_patches/refs/heads/main/next/0001-add-more-managers.patch | patch -p1
        # --- END OF ADDED SECTION ---

        local susfs_ksu_patch_file="../../kernel_patches/next/0001-SuSFS-1.5.9-v6.patch"
        if [ -f "$susfs_ksu_patch_file" ]; then
            log_info "Found SuSFS patch for KernelSU, applying..."
            patch -p1 < "$susfs_ksu_patch_file"
        else
            # This warning will now correctly show the full path it tried to check
            log_warn "KernelSU SuSFS patch not found at '$(readlink -f "$susfs_ksu_patch_file")', skipping."
        fi
    )
    
    # Build script modifications
    log_info "Applying build script tweaks (disable -dirty tag)..."
    sed -i '/# Check for uncommitted changes\./,/fi/d' ./scripts/setlocalversion
    sed -i '2s/check_defconfig//' ./build.config.gki

    # Remove GKI protected ABI symbol exports
    log_info "Removing GKI protected ABI exports to prevent symbol conflicts..."
    rm -v android/abi_gki_protected_exports_*

    cd ..
}

compile_kernel() {
    read -rp "Enter a build identifier for the ZIP filename (e.g., v1.2): " build_version
    export ZIP_NAME_RAW="AK3-A14-${KERNEL_VERSION}-KSUN-$(timestamp)-${build_version}.zip"
    
    log_step "Starting kernel compilation for: ${ZIP_NAME_RAW}"
    cd "$KERNEL_SOURCE_DIR"

    # Clean previous output
    if [ -d "out" ]; then
        read -rp "The 'out' folder exists. Delete it? [Y/n]: " reply
        if [[ ! "$reply" =~ ^[nN]$ ]]; then
            rm -rf out
            log_info "'out' folder deleted."
        fi
    fi
    
    # Build command
    make -j"$(nproc --all)" LLVM_IAS=1 LLVM=1 ARCH=arm64 \
        CLANG_TRIPLE=aarch64-linux-gnu- \
        CROSS_COMPILE="${CROSS_COMPILE_AARCH64_PATH}/aarch64-none-linux-gnu-" \
        CROSS_COMPILE_COMPAT="${CROSS_COMPILE_ARM_PATH}/arm-none-eabi-" \
        CC="ccache clang" LD=ld.lld HOSTLD=ld.lld \
        O=out gki_defconfig all

    cd ..
    log_info "Kernel compiled successfully!"
}

package_zip() {
    log_step "Packaging flashable ZIP..."
    
    local image_path="${KERNEL_SOURCE_DIR}/out/arch/arm64/boot/Image"
    [ ! -f "$image_path" ] && log_error "Compiled kernel Image not found!"
    
    cp -v "$image_path" ./AnyKernel3-p8a/
    
    cd ./AnyKernel3-p8a
    rm -rf .git                               # <-- ADD THIS LINE
    rm -f ./*.zip                             # Clean old zips
    zip -r9 "$ZIP_NAME_RAW" ./*
    rm -f Image                               # <-- ADD THIS LINE
    
    # Organize output
    local output_dir="../builds/${KERNEL_VERSION}"
    mkdir -p "$output_dir"
    mv "$ZIP_NAME_RAW" "$output_dir/"
    
    cd ..
    export FINAL_ZIP_PATH="${output_dir}/${ZIP_NAME_RAW}"
    log_info "ZIP created successfully!"
}

# --- Execution ---
main() {
    check_dependencies
    check_toolchain_paths
    setup_environment
    clone_repositories
    prepare_kernel_source
    configure_kernel
    apply_patches
    compile_kernel
    package_zip

    # Final Summary
    END_TIME=$(date +%s)
    TOTAL_TIME=$((END_TIME - START_TIME))
    log_step "Build Finished!"
    log_info "Total time: $((TOTAL_TIME / 60)) minutes and $((TOTAL_TIME % 60)) seconds."
    log_info "Output file: ${GREEN}${BOLD}${FINAL_ZIP_PATH}${ENDCOLOR}"
}

# Run the main function
main
