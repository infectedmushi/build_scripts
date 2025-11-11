#!/bin/bash
RED="\e[31m"
GREEN="\e[32m"
ENDCOLOR="\e[0m"
bold=$(tput bold)
normal=$(tput sgr0)
timestamp()
{
 date +"%Y%m%d-%H%M"
}

export USE_CCACHE=1
export CCACHE_DIR=/mnt/ccache/.ccache
export LLVM_CACHE_PATH=~/.cache/llvm


read -p "Enter the value for BUILD: " BUILD
echo "You entered: $BUILD"
export ZIP_NAME_RAW="AK3-A14-6.1.155-SukiSU-$(timestamp)-$BUILD.zip"

# Prompt the user for the KernelSU-Next version
#read -p "Enter KSU_VERSION value (e.g. 13000): " KSU_VERSION

# Use the input in your build process, or export it for Makefile
#export KSU_VERSION

echo -e "${GREEN}${bold}Remove folders${normal}${ENDCOLOR}"

rm -rf susfs4ksu
rm -rf AnyKernel3-p8a
rm -rf SukiSU_patch
#rm -rf common

echo -e "${GREEN}${bold}Clone repos${normal}${ENDCOLOR}"
git clone https://gitlab.com/pershoot/susfs4ksu.git -b gki-android14-6.1-dev
git clone https://github.com/deepongi-labs/AnyKernel3-p8a -b sukisu
git clone git@github.com:SukiSU-Ultra/SukiSU_patch.git
#git clone https://github.com/infectedmushi/kernel_patches -b main
#git clone --depth=1 git@github.com:aosp-mirror/kernel_common.git -b android14-6.1 common

echo -e "${GREEN}${bold}Add clang path${normal}${ENDCOLOR}"
#export PATH=/mnt/Android/new_kernel_ksun/neutron-clang/bin:$PATH
export PATH=/mnt/Android/clang-22/bin:$PATH


echo -e "${GREEN}${bold}Enter kernel directory${normal}${ENDCOLOR}"
cd common

# Set your directory name; for example:
DIR="KernelSU"

if [ -d "$DIR" ]; then
    # The directory exists; do something
    echo "Directory '$DIR' exists."
    # Add your actions here, for example:
    rm -rf KernelSU
    git reset --hard 86676b1f0
    git clean -fdx
else
    # The directory does NOT exist
    echo "Directory '$DIR' does not exist."
    # Optional: do something else
    git reset --hard 86676b1f0
    git clean -fdx
fi

# Asks if the kernel is for Pixel 8a
read -p "Is the kernel for Pixel 8a? [y/n]: " PIXEL8A

if [[ "$PIXEL8A" =~ ^[yY]$ ]]; then
    echo "Configuring gki_defconfig for Pixel 8a..."
    CONFIG_FILE=arch/arm64/configs/gki_defconfig

    # Super bloco seguro de otimizações usando array
    opts=(
        # Memory and address space (already in AOSP gki_defconfig, ensure for Tensor G3)
"CONFIG_ARM64_CORTEX_X3=y"
"CONFIG_ARM64_CORTEX_A715=y"
"CONFIG_ARM64_CORTEX_A510=y"
"CONFIG_ARM64_VA_BITS=48"
"CONFIG_ARM64_PA_BITS=48"
"CONFIG_ARM64_TAGGED_ADDR_ABI=y"
"CONFIG_ARM64_SVE=y"
"CONFIG_ARM64_BTI=y"
"CONFIG_ARM64_PTR_AUTH=y"
"CONFIG_SCHED_MC=y"
"CONFIG_SCHED_CORE=y"
"CONFIG_ENERGY_MODEL=y"
"CONFIG_UCLAMP_TASK=y"
"CONFIG_UCLAMP_TASK_GROUP=y"
"CONFIG_SCHEDUTIL=y"
"CONFIG_CPU_FREQ=y"
"CONFIG_CPUFREQ_DT=y"
"CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y"
"CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y"
"CONFIG_OPP=y"
"CONFIG_CPU_IDLE=y"
"CONFIG_ARM_PSCI_CPUIDLE=y"
"CONFIG_THERMAL=y"
"CONFIG_CPU_THERMAL=y"
"CONFIG_DEVFREQ_THERMAL=y"
"CONFIG_THERMAL_GOV_POWER_ALLOCATOR=y"
"CONFIG_THERMAL_GOV_STEP_WISE=y"
"CONFIG_THERMAL_GOV_FAIR_SHARE=y"
"CONFIG_THERMAL_EMULATION=y"
"CONFIG_THERMAL_WRITABLE_TRIPS=y"
"CONFIG_POWER_CAP=y"
"CONFIG_PERF_EVENTS=y"
"CONFIG_ARM64_SME=y"
"CONFIG_NUMA_BALANCING=y"
"CONFIG_CMA=y"
"CONFIG_CMA_AREAS=7"
"CONFIG_TCP_CONG_ADVANCED=y"
"CONFIG_TCP_CONG_CUBIC=y"
"CONFIG_NET_SCH_FQ_CODEL=y"
"CONFIG_DEFAULT_FQ_CODEL=y"
"CONFIG_NET_SCH_CAKE=y"
"CONFIG_DEFAULT_CAKE=y"
"CONFIG_DEFAULT_TCP_CONG=\"bbr\""
"CONFIG_F2FS_FS=y"
"CONFIG_F2FS_FS_XATTR=y"
"CONFIG_F2FS_FS_POSIX_ACL=y"
"CONFIG_F2FS_FS_SECURITY=y"
"CONFIG_F2FS_FS_COMPRESSION=y"
    )

    # Aplica cada opção se não existir
    for opt in "${opts[@]}"; do
        grep -q "$opt" "$CONFIG_FILE" || echo "$opt" >> "$CONFIG_FILE"
    done

    echo "gki_defconfig configured successfully for Pixel 8a."
else
    echo "PIXEL8A not set. Skipping Pixel 8a configuration."
fi


echo -e "${GREEN}${bold}Adding LTO ...${normal}${ENDCOLOR}"

read -p "Do you want LTO full? (yes/thin/none): " lto_choice

if [ "$lto_choice" = "yes" ]; then
    echo "CONFIG_LTO_CLANG_FULL=y" >> ./arch/arm64/configs/gki_defconfig
elif [ "$lto_choice" = "thin" ]; then
    echo "CONFIG_LTO_CLANG_THIN=y" >> ./arch/arm64/configs/gki_defconfig
elif [ "$lto_choice" = "none" ]; then
    echo "CONFIG_LTO=n" >> ./arch/arm64/configs/gki_defconfig
else
    echo "Unknown choice: $lto_choice"
    exit 1
fi

echo -e "${GREEN}${bold}Adding SukiSU-Ultra${normal}${ENDCOLOR}"
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/susfs-main/kernel/setup.sh" | bash -s susfs-main

echo -e "${GREEN}${bold}Applying SUSFS patches...${normal}${ENDCOLOR}"
cp -v ../susfs4ksu/kernel_patches/fs/* ./fs/
cp -v ../susfs4ksu/kernel_patches/include/linux/* ./include/linux/
patch -p1 --forward < ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch

echo -e "${GREEN}${bold}Applying SukiSU patches...${normal}${ENDCOLOR}"
patch -p1 < ../SukiSU_patch/hooks/scope_min_manual_hooks_v1.6.patch
patch -p1 < ../SukiSU_patch/69_hide_stuff.patch

echo -e "${GREEN}${bold}Apply fix-clidr-uninitialized.patch ${normal}${ENDCOLOR}"
patch -p1 --forward < ../fix-clidr-uninitialized.patch

echo -e "${GREEN}${bold}Removing exports...${normal}${ENDCOLOR}"
rm -v android/abi_gki_protected_exports_*

echo -e "${GREEN}${bold}Adding KSU configuration settings to gki_defconfig...${normal}${ENDCOLOR}"
echo 'CONFIG_LOCALVERSION_AUTO=n' | tee -a ./arch/arm64/configs/gki_defconfig
echo 'CONFIG_LOCALVERSION="-deepongi"' | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_DEBUG=n" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_MANUAL_HOOK=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_SUS_PATH=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_SUS_SU=n" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS_SUS_MAP=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_TMPFS_XATTR=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_TMPFS_POSIX_ACL=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_IP_NF_TARGET_TTL=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_IP6_NF_TARGET_HL=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_IP6_NF_MATCH_HL=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_TCP_CONG_ADVANCED=y" | tee -a ./arch/arm64/configs/gki_defconfig 
echo "CONFIG_TCP_CONG_BBR=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_NET_SCH_FQ=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_TCP_CONG_BIC=n" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_TCP_CONG_WESTWOOD=n" | tee -a ./arch/arm64/configs/gki_defconfig
echo "CONFIG_TCP_CONG_HTCP=n" | tee -a ./arch/arm64/configs/gki_defconfig
#echo "CONFIG_KSU_SWITCH_MANAGER=y" | tee -a ./arch/arm64/configs/gki_defconfig
# Otimizações
echo "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y" | tee -a ./arch/arm64/configs/gki_defconfig
echo 'CONFIG_CC_FLAGS="-O3 -flto -ffunction-sections -fdata-sections"' | tee -a ./arch/arm64/configs/gki_defconfig
# Ativar ccache
echo "CONFIG_CCACHE=y" | tee -a ./arch/arm64/configs/gki_defconfig



echo -e "${GREEN}${bold}Add deepongi+ tag, remove -dirty tag, check_defconfig...${normal}${ENDCOLOR}"

#sed -i '$s|echo "\$res"|echo "\$res-deepongi+"|' ./scripts/setlocalversion
sed -i '/# Check for uncommitted changes\./,/fi/d' ./scripts/setlocalversion
sed -i '2s/check_defconfig//' ./build.config.gki

rm -rf out
make clean

echo -e "${GREEN}${bold}Entering kernel dir and compiling...${normal}${ENDCOLOR}"
time make -j64 \
LLVM_IAS=1 \
LLVM=1 \
ARCH=arm64 \
CLANG_TRIPLE=aarch64-linux-gnu- \
CROSS_COMPILE_COMPAT=/mnt/Android/new_kernel_ksun/arm-gnu-toolchain-14.3.rel1-x86_64-arm-none-eabi/bin/arm-none-eabi- \
CROSS_COMPILE=/mnt/Android/new_kernel_ksun/arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu- \
CC="ccache clang" \
LD=ld.lld \
HOSTLD=ld.lld \
O=out \
gki_defconfig all


cd ..
echo -e "${GREEN}${bold}Zip in AK3...${normal}${ENDCOLOR}"
cp -v ./common/out/arch/arm64/boot/Image ./AnyKernel3-p8a
cd ./AnyKernel3-p8a
rm -rf .git
zip -r $ZIP_NAME_RAW ./*
rm -rf Image
mv $ZIP_NAME_RAW ../builds/6.1.155

echo -e "${GREEN}${bold}All done...${normal}${ENDCOLOR}"
