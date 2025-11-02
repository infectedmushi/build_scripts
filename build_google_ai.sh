#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error.
# Ensure that a pipeline's exit code is that of the last command to exit with a non-zero status.
set -euo pipefail

## ---------------------------------------------------------------------------
## 📜 Configuration Variables
##
## Please update these paths to match your build environment.
## ---------------------------------------------------------------------------

# Kernel root directory (as specified in the prompt)
KERNEL_ROOT_NAME="common"
KERNEL_ROOT="$(pwd)/${KERNEL_ROOT_NAME}"

# Number of parallel jobs for 'make'
NUM_JOBS=32

# Path to your Clang toolchain
CLANG_PATH="/mnt/Android/clang-22"

# Path to your arm-none-eabi toolchain (for CLANG_COMPAT)
CLANG_COMPAT_PATH="/mnt/Android/new_kernel_suki/arm-gnu-toolchain-14.3.rel1-x86_64-arm-none-eabi"

# Path to your aarch64-none-linux-gnu toolchain (for CROSS_COMPILE)
CROSS_COMPILE_PATH="/mnt/Android/new_kernel_suki/arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu"

# Local patches that must exist in the current directory
# These were CPo'd from `../` in the original script.
LOCAL_PATCHES=(
    "0001-fix-clang22-warning-Wdefault-const-init-var-unsafe.patch"
    "0001-fix-clang22-warning-Wdefault-const-init-field-unsafe.patch"
    "fix-clidr-uninitialized.patch"
)

## ---------------------------------------------------------------------------
## 🚀 Helper Functions
## ---------------------------------------------------------------------------

# Function for logging colored messages
log() {
    echo -e "\n🟢 \e[1m$@\e[0m"
}

# Function for logging errors
error() {
    echo -e "\n🔴 \e[1;31mERROR: $@\e[0m"
    exit 1
}

## ---------------------------------------------------------------------------
## 🛠️ Build Script
## ---------------------------------------------------------------------------

# Step 0: Validate environment
log "Validating build environment..."

if [ ! -d "${CLANG_PATH}" ]; then
    error "Clang directory not found: ${CLANG_PATH}"
fi
if [ ! -d "${CLANG_COMPAT_PATH}" ]; then
    error "CLANG_COMPAT directory not found: ${CLANG_COMPAT_PATH}"
fi
if [ ! -d "${CROSS_COMPILE_PATH}" ]; then
    error "CROSS_COMPILE directory not found: ${CROSS_COMPILE_PATH}"
fi

for patch in "${LOCAL_PATCHES[@]}"; do
    if [ ! -f "$patch" ]; then
        error "Local patch '$patch' not found. Please place it in the same directory as this script."
    fi
done

log "All toolchains and patches found."

# Step 1: Clone Kernel & Setup KernelSU
log "Cloning AOSP kernel common (android14-6.1-2025-09)..."
git clone --depth=1 git@github.com:aosp-mirror/kernel_common.git -b android14-6.1-2025-06 "${KERNEL_ROOT_NAME}"

log "Running KernelSU setup script (susfs-test)..."
cd "${KERNEL_ROOT}"
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-test
cd ..

# Step 2: Apply susfs4ksu Patches
log "Cloning and applying susfs4ksu patches..."
rm -rf susfs4ksu
# Replaced 'gcl' with 'git clone' and used HTTPS for compatibility
git clone --depth=1 https://github.com/ShirkNeko/susfs4ksu -b gki-android14-6.1-dev susfs4ksu

cd "${KERNEL_ROOT}"
cp -v ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch ./
cp -v ../susfs4ksu/kernel_patches/fs/* ./fs/
cp -v ../susfs4ksu/kernel_patches/include/linux/* ./include/linux/
patch -p1 --forward --fuzz=3 < 50_add_susfs_in_gki-android14-6.1.patch
cd ..

# Step 3: Apply SukiSU_patch
log "Cloning and applying SukiSU_patch..."
rm -rf SukiSU_patch
# Replaced 'gcl' with 'git clone' and SSH with HTTPS
git clone --depth=1 https://github.com/SukiSU-Ultra/SukiSU_patch.git SukiSU_patch

cd "${KERNEL_ROOT}"
cp -v ../SukiSU_patch/hooks/scope_min_manual_hooks_v1.5.patch ./
patch -p1 --forward < scope_min_manual_hooks_v1.5.patch
rm -v android/abi_gki_protected_exports_*
cd ..

# Step 4: Configure Kernel Options
log "Appending custom KConfig options to gki_defconfig..."
CONFIG_FILE="${KERNEL_ROOT}/arch/arm64/configs/gki_defconfig"

# Use a 'here document' (cat <<EOF) for clean, multi-line appending
cat <<EOF >> "${CONFIG_FILE}"

# --- Custom SukiSU / KernelSU Configs ---
CONFIG_KSU=y
CONFIG_KPM=y
CONFIG_KSU_SUSFS_SUS_SU=n
CONFIG_KSU_MANUAL_HOOK=y
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
CONFIG_KSU_SUSFS_ADD_SUS_MAP=y
CONFIG_KSU_MANUAL_SU=n
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
CONFIG_DEFAULT_BBR=y
CONFIG_BPF_STREAM_PARSER=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_IP_SET=y
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_KALLSYMS=y
# --- End Custom Configs ---
EOF

# Step 5: Final Patches & Tweaks
log "Applying final tweaks and local patches..."
cd "${KERNEL_ROOT}"
sed -i '/# Check for uncommitted changes\./,/fi/d' ./scripts/setlocalversion
sed -i '2s/check_defconfig//' ./build.config.gki
mkdir -p out

log "Applying local clang/clidr fixes..."
cp -v ../0001-fix-clang22-warning-Wdefault-const-init-var-unsafe.patch ./
patch -p1 --forward < 0001-fix-clang22-warning-Wdefault-const-init-var-unsafe.patch

cp -v ../0001-fix-clang22-warning-Wdefault-const-init-field-unsafe.patch ./
patch -p1 --forward < 0001-fix-clang22-warning-Wdefault-const-init-field-unsafe.patch

cp -v ../fix-clidr-uninitialized.patch ./
patch -p1 --forward < fix-clidr-uninitialized.patch

# Step 6: Build the Kernel
log "Starting the kernel build with ${NUM_JOBS} jobs..."
export PATH="${CLANG_PATH}/bin:${PATH}"

# Broke the long 'make' command into multiple lines for readability
make -j${NUM_JOBS} \
    LLVM_IAS=1 LLVM=1 \
    ARCH=arm64 \
    CLANG_COMPAT="${CLANG_COMPAT_PATH}/bin/arm-none-eabi-" \
    CROSS_COMPILE="${CROSS_COMPILE_PATH}/bin/aarch64-none-linux-gnu-" \
    CC="clang" \
    LD=ld.lld \
    HOSTLD=ld.lld \
    O=out \
    gki_defconfig all

# Return to the original directory
cd ..

cp -v /mnt/Android/new_kernel_suki/common/out/arch/arm64/boot/Image /mnt/Android/new_kernel_suki/SukiSU_patch/kpm
./patch_linux Image
mv oImage Image
cp -v Image /mnt/Android/new_kernel_suki/AnyKernel3-p8a
zip -r AK3-A14-6.1.145-SUKISU-20251102-1724-r13473.zip ./*
mv AK3-A14-6.1.145-SUKISU-20251102-1724-r13473.zip ../builds/6.1.145


log "Build script finished successfully."
log "Your build output is in: ${KERNEL_ROOT}/out/"
