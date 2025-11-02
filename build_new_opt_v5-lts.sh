#!/usr/bin/env bash
# Enhanced Kernel Build Script (idempotent, CI-friendly)
# - KernelSU-Next (next-susfs) integration
# - SuSFS patches for android14-6.1
# - Baseband-guard integration
# - LTO control, networking/BBR/IPSet configs
# - CI-safe artifact labeling (UTC[ -shortSHA]), never "nogit" or "build" in names

set -euo pipefail

# ---------- Colors ----------
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; ENDCOLOR="\e[0m"
bold=$(tput bold 2>/dev/null || true); normal=$(tput sgr0 2>/dev/null || true)

# ---------- Logging ----------
ts() { date +"%Y%m%d-%H%M"; }
ts_utc() { TZ=UTC date -u +"%Y%m%dT%H%MZ"; }
log_info()    { echo -e "${GREEN}${bold}[INFO]${normal} $*${ENDCOLOR}"; }
log_warn()    { echo -e "${YELLOW}${bold}[WARN]${normal} $*${ENDCOLOR}"; }
log_error()   { echo -e "${RED}${bold}[ERROR]${normal} $*${ENDCOLOR}"; }
log_step()    { echo -e "${BLUE}${bold}==>${normal} $*${ENDCOLOR}"; }

START_EPOCH=$(date +%s)
trap 'rc=$?; end=$(date +%s); dur=$((end-START_EPOCH)); [[ $rc -eq 0 ]] || log_error "Exited with code $rc after ${dur}s"; exit $rc' EXIT

# ---------- Defaults (env-overridable) ----------
: "${BUILD:=dev}"
: "${PIXEL8A:=y}"                   # y/n
: "${LTO_TYPE:=thin}"               # full|thin|none
: "${ZIP_PREFIX:=AK3-A14-6.1.155-KSUN}"
: "${CLANG_PATH:=/mnt/Android/clang-22/bin}"
: "${ARM64_TOOLCHAIN:=/mnt/Android/new_kernel_ksun/arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-}"
: "${ARM32_TOOLCHAIN:=/mnt/Android/new_kernel_ksun/arm-gnu-toolchain-14.3.rel1-x86_64-arm-none-eabi/bin/arm-none-eabi-}"
: "${KERNEL_DIR:=common}"
: "${CONFIG_FILE:=arch/arm64/configs/gki_defconfig}"
: "${OUT_DIR:=out}"
: "${RESET_COMMIT:=67d6b8170}"
: "${THREADS:=$(nproc)}"
: "${BUILD_CLEAN:=always}"          # auto|always|never
: "${RETRY:=3}"
: "${REPO_DEPTH:=1}"                # 0 to disable shallow
: "${KSUN_BRANCH:=next-susfs}"
: "${ANYKERNEL_DIR:=AnyKernel3-p8a}"
: "${ANYKERNEL_BRANCH:=gki-2.0}"
: "${SUSFS_REPO:=https://gitlab.com/pershoot/susfs4ksu.git}"
: "${SUSFS_BRANCH:=gki-android14-6.1-lts-dev}"
: "${PATCHES_REPO:=https://github.com/infectedmushi/kernel_patches}"
: "${PATCHES_BRANCH:=main}"
: "${BUILDS_DIR:=builds/6.1.155}"
: "${LOCALVERSION:=-deepongi}"

export USE_CCACHE="${USE_CCACHE:-1}"
export CCACHE_DIR="${CCACHE_DIR:-/mnt/ccache/.ccache}"
export LLVM_CACHE_PATH="${LLVM_CACHE_PATH:-$HOME/.cache/llvm}"

# ---------- Helpers ----------
cmd_exists() { command -v "$1" &>/dev/null; }
retry() { local n=0; local max=$1; shift; until "$@"; do n=$((n+1)); (( n>=max )) && return 1; sleep $((n)); done; }

git_clone_or_update() {
  local url=$1 dir=$2 branch=$3 depth=$4
  if [[ -d "$dir/.git" ]]; then
    log_info "Updating $dir"
    (cd "$dir" && git fetch --all --prune && git checkout "$branch" && git reset --hard "origin/$branch") || return 1
  else
    local depth_args=()
    [[ "${depth}" != "0" ]] && depth_args=(--depth "$depth")
    retry "$RETRY" git clone "${depth_args[@]}" -b "$branch" "$url" "$dir" || return 1
  fi
}

append_unique_cfg() {
  local file=$1 line=$2
  grep -q -E "^${line//\//\\/}$" "$file" 2>/dev/null || printf "%s\n" "$line" >> "$file"
}

set_cfg_toggle() {
  local file=$1 key=$2 val=$3
  sed -i -E "/^#?\s*${key}=.*/d" "$file" 2>/dev/null || true
  case "$val" in
    y|n) printf "%s=%s\n" "$key" "$([ "$val" = y ] && echo y || echo n)" >> "$file" ;;
    \"*\"|\'*\') printf "%s=%s\n" "$key" "$val" >> "$file" ;;
    *) printf "%s=\"%s\"\n" "$key" "$val" >> "$file" ;;
  esac
}

apply_patch_forward() {
  local patch_file=$1
  if patch -p1 --dry-run --forward < "$patch_file" &>/dev/null; then
    # use unified mode with input file for clearer diagnostics
    patch -p1 -ui "$patch_file"
    log_info "Applied patch: $patch_file"
  else
    log_warn "Patch likely already applied or context mismatch: $patch_file"
  fi
}

git_short_sha() {
  # Allow CI to inject a SHA; else detect; never print placeholders.
  if [[ -n "${GIT_SHORT_SHA:-}" ]]; then
    printf "%s" "${GIT_SHORT_SHA}"
    return
  fi
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git rev-parse --short=7 HEAD 2>/dev/null || true
  else
    echo ""
  fi
}

compose_label() {
  # Example: 20251015T1338Z-1a2b3c4 or 20251015T1338Z when no SHA
  local ts sha
  ts="$(ts_utc)"
  sha="$(git_short_sha)"
  if [[ -n "$sha" ]]; then
    printf "%s-%s" "$ts" "$sha"
  else
    printf "%s" "$ts"
  fi
}

# ---------- Derive BUILD from KernelSU KSU_VERSION ----------
derive_build_from_kernelsu() {
  local ksu_dir="KernelSU-Next"
  local fallback="11998"  # mirrors KSU Makefile fallback
  if [[ -d "$ksu_dir/.git" ]]; then
    (
      cd "$ksu_dir"
      if [[ -f .git/shallow ]]; then
        git fetch --unshallow || true
      else
        git fetch --all --prune || true
      fi
    )
    local count=""
    count=$(cd "$ksu_dir" && /usr/bin/env PATH="$PATH":/usr/bin:/usr/local/bin git rev-list --count origin/HEAD 2>/dev/null || echo "")
    if [[ -n "$count" && "$count" =~ ^[0-9]+$ ]]; then
      local ver=$((10000 + count + 200))
      export BUILD="$ver"
      log_info "BUILD set from KernelSU KSU_VERSION: $BUILD"
      return
    else
      log_warn "Could not compute KSU rev-list count; fallback BUILD=$fallback"
    fi
  else
    log_warn "KernelSU-Next .git not found; fallback BUILD=$fallback"
  fi
  export BUILD="$fallback"
}

# ---------- Validate tools ----------
validate_requirements() {
  log_step "Validating requirements"

  # --- FIX: Validate and add Clang to PATH *before* checking for it ---
  [[ -d "$CLANG_PATH" ]] || { log_error "Clang path not found: $CLANG_PATH"; exit 1; }
  export PATH="$CLANG_PATH:$PATH"
  # --- End Fix ---

  local tools=(git make clang zip patch curl sed grep awk ccache)
  local missing=()
  for t in "${tools[@]}"; do cmd_exists "$t" || missing+=("$t"); done
  [[ ${#missing[@]} -eq 0 ]] || { log_error "Missing tools: ${missing[*]}"; exit 1; }

  # This check is now redundant but fine to leave
  clang --version | head -n1 || { log_error "clang not runnable"; exit 1; }
  log_info "ccache: $(ccache -V | head -n1 || echo disabled)"
}

# ---------- Repos ----------
setup_repositories() {
  log_step "Setting up repositories"

  # susfs4ksu
  if [[ -d "susfs4ksu/.git" ]]; then
    log_info "Updating susfs4ksu"
    (cd susfs4ksu && git fetch --all --prune && git checkout "$SUSFS_BRANCH" && git reset --hard "origin/$SUSFS_BRANCH")
  else
    retry "$RETRY" git clone ${REPO_DEPTH:+--depth "$REPO_DEPTH"} -b "$SUSFS_BRANCH" "$SUSFS_REPO" susfs4ksu
  fi

  # AnyKernel3
  if [[ -d "$ANYKERNEL_DIR/.git" ]]; then
    log_info "Updating $ANYKERNEL_DIR"
    (cd "$ANYKERNEL_DIR" && git fetch --all --prune && git checkout "$ANYKERNEL_BRANCH" && git reset --hard "origin/$ANYKERNEL_BRANCH")
  else
    if [[ -d "$ANYKERNEL_DIR" && "$BUILD_CLEAN" == "always" ]]; then
      log_warn "$ANYKERNEL_DIR exists without .git; removing due to BUILD_CLEAN=always"
      rm -rf "$ANYKERNEL_DIR"
    fi
    if [[ ! -d "$ANYKERNEL_DIR" ]]; then
      retry "$RETRY" git clone ${REPO_DEPTH:+--depth "$REPO_DEPTH"} -b "$ANYKERNEL_BRANCH" "https://github.com/deepongi-labs/${ANYKERNEL_DIR}" "$ANYKERNEL_DIR"
    else
      log_info "Reusing existing $ANYKERNEL_DIR (no .git); skipping clone"
    fi
  fi

  # kernel_patches
  if [[ -d "kernel_patches/.git" ]]; then
    log_info "Updating kernel_patches"
    (cd kernel_patches && git fetch --all --prune && git checkout "$PATCHES_BRANCH" && git reset --hard "origin/$PATCHES_BRANCH")
  else
    retry "$RETRY" git clone ${REPO_DEPTH:+--depth "$REPO_DEPTH"} -b "$PATCHES_BRANCH" "$PATCHES_REPO" kernel_patches
  fi

  log_info "Repositories ready"
}

# ---------- Compiler ----------
setup_compiler() {
  log_step "Setting up compiler"
  export PATH="$CLANG_PATH:$PATH"
  cmd_exists clang || { log_error "clang not found in PATH"; exit 1; }
  log_info "Using $(clang --version | head -n1)"
}

# ---------- Kernel source ----------
prepare_kernel_source() {
  log_step "Preparing kernel source"
  [[ -d "$KERNEL_DIR" ]] || { log_error "Kernel directory not found: $KERNEL_DIR"; exit 1; }
  cd "$KERNEL_DIR"
  git clean -fdx || log_warn "git clean failed"
  git reset --hard "$RESET_COMMIT" || { log_error "Failed reset to $RESET_COMMIT"; exit 1; }
  rm -rf KernelSU-Next || true
  log_info "Kernel source reset to $RESET_COMMIT"
}

# ---------- Device config ----------
configure_pixel8a() {
  if [[ "${PIXEL8A,,}" != "y" ]]; then
    log_info "Skipping Pixel 8a config"
    return
  fi
  log_step "Configuring Pixel 8a (Tensor G3)"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_CORTEX_X3=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_CORTEX_A715=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_CORTEX_A510=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_VA_BITS=48"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_PA_BITS=48"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_TAGGED_ADDR_ABI=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_SVE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_BTI=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_PTR_AUTH=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_SCHED_MC=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_SCHED_CORE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ENERGY_MODEL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_UCLAMP_TASK=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_UCLAMP_TASK_GROUP=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_SCHEDUTIL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CPU_FREQ=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CPUFREQ_DT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_OPP=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CPU_IDLE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM_PSCI_CPUIDLE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_THERMAL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CPU_THERMAL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_DEVFREQ_THERMAL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_THERMAL_GOV_POWER_ALLOCATOR=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_THERMAL_GOV_STEP_WISE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_THERMAL_GOV_FAIR_SHARE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_THERMAL_EMULATION=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_THERMAL_WRITABLE_TRIPS=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_POWER_CAP=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_PERF_EVENTS=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_SME=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_NUMA_BALANCING=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CMA=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CMA_AREAS=7"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_ADVANCED=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_CUBIC=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_NET_SCH_FQ_CODEL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_DEFAULT_FQ_CODEL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_NET_SCH_CAKE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_DEFAULT_CAKE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_DEFAULT_TCP_CONG=\"bbr\""
  append_unique_cfg "$CONFIG_FILE" "CONFIG_F2FS_FS=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_F2FS_FS_XATTR=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_F2FS_FS_POSIX_ACL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_F2FS_FS_SECURITY=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_F2FS_FS_COMPRESSION=y"
  log_info "Pixel 8a configuration done"
}

# ---------- LTO ----------
configure_lto() {
  log_step "Configuring LTO: $LTO_TYPE"
  sed -i -E '/^CONFIG_LTO_(CLANG_(FULL|THIN)|NONE)=/d' "$CONFIG_FILE" 2>/dev/null || true
  case "${LTO_TYPE}" in
    full) append_unique_cfg "$CONFIG_FILE" "CONFIG_LTO_CLANG_FULL=y" ;;
    thin) append_unique_cfg "$CONFIG_FILE" "CONFIG_LTO_CLANG_THIN=y" ;;
    none) append_unique_cfg "$CONFIG_FILE" "CONFIG_LTO_NONE=y" ;;
    *) log_error "Invalid LTO_TYPE: $LTO_TYPE"; exit 1 ;;
  esac
  log_info "LTO set"
}

# ---------- KernelSU ----------
install_kernelsu() {
  log_step "Installing KernelSU-Next ($KSUN_BRANCH)"
  # Use refs/heads path as in public guides
  retry "$RETRY" bash -c \
    "curl -LSs https://raw.githubusercontent.com/pershoot/KernelSU-Next/refs/heads/${KSUN_BRANCH}/kernel/setup.sh | bash -s ${KSUN_BRANCH}"
  log_info "KernelSU-Next installed"
}

# ---------- Baseband-guard (BBG) ----------
add_bbg() {
  log_step "Adding BBG (Baseband-guard)"
  [[ -f "Makefile" && -d "security" ]] || { log_error "Not in kernel top-level; cannot add BBG"; exit 1; }
  if ! curl -LSs https://raw.githubusercontent.com/vc-teahouse/Baseband-guard/main/setup.sh | bash; then
    log_error "BBG setup failed"; exit 1
  fi
  if ! grep -q "^CONFIG_BBG=y$" "$CONFIG_FILE"; then
    echo "CONFIG_BBG=y" >> "$CONFIG_FILE"
    log_info "Enabled CONFIG_BBG in $CONFIG_FILE"
  else
    log_warn "CONFIG_BBG already enabled in $CONFIG_FILE"
  fi
  local kcfg="security/Kconfig"
  if [[ -f "$kcfg" ]]; then
    if ! awk '/^config LSM$/{f=1} f && /^help$/{f=0} f && /default/ && /baseband_guard/{found=1} END{exit !found}' "$kcfg"; then
      sed -i '/^config LSM$/,/^help$/{
        /^[[:space:]]*default/ {
          /baseband_guard/! s/\<landlock\>/landlock,baseband_guard/
        }
      }' "$kcfg"
      log_info "Added baseband_guard to LSM default in $kcfg"
    else
      log_warn "baseband_guard already present in LSM default"
    fi
  else
    log_warn "security/Kconfig not found; skipping LSM default update"
  fi
}

# ---------- SUSFS patches ----------
apply_susfs_patches() {
  log_step "Applying SUSFS patches"
  
  # Copy SUSFS patches from susfs4ksu repository
  cp -fv ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch ./
  cp -fv ../susfs4ksu/kernel_patches/60_scope-minimized_manual_hooks.patch ./
  cp -fv ../susfs4ksu/kernel_patches/70_modules_no-mmio_tracepoints.patch ./
  
  # Copy SUSFS source files
  mkdir -p fs include/linux
  cp -rfv ../susfs4ksu/kernel_patches/fs/* ./fs/ || true
  cp -rfv ../susfs4ksu/kernel_patches/include/linux/* ./include/linux/ || true
  
  # Apply patches in order
  apply_patch_forward 50_add_susfs_in_gki-android14-6.1.patch
  apply_patch_forward 60_scope-minimized_manual_hooks.patch
  apply_patch_forward 70_modules_no-mmio_tracepoints.patch
  
  log_info "SUSFS patches synced (including 70_modules_no-mmio_tracepoints)"
}

# ---------- Extra patches ----------
apply_additional_patches() {
  log_step "Applying additional patches"
  if [[ -f "../fix-clidr-uninitialized.patch" ]]; then
    cp -fv ../fix-clidr-uninitialized.patch ./
    apply_patch_forward fix-clidr-uninitialized.patch
  else
    log_warn "fix-clidr-uninitialized.patch not found; skipping"
  fi
}

# ---------- Kernel config ----------
configure_kernel() {
  log_step "Tuning kernel config"

  # Enforce removal so ABI lists cannot block linking with SuSFS
  if compgen -G "android/abi_gki_protected_exports_*" > /dev/null; then
    rm -f android/abi_gki_protected_exports_*
  fi

  set_cfg_toggle "$CONFIG_FILE" "CONFIG_LOCALVERSION_AUTO" n
  set_cfg_toggle "$CONFIG_FILE" "CONFIG_LOCALVERSION" "\"$LOCALVERSION\""

  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_KPROBES_HOOK=n"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_DEBUG=n"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_THRONE_TRACKER_ALWAYS_THREADED=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_ALLOWLIST_WORKAROUND=n"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_LSM_SECURITY_HOOKS=y"

  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SUS_PATH=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_TRY_UMOUNT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SUS_SU=n"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SUS_MAP=y"

  append_unique_cfg "$CONFIG_FILE" "CONFIG_TMPFS_XATTR=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TMPFS_POSIX_ACL=y"

  # Networking
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_NF_TARGET_TTL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP6_NF_TARGET_HL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP6_NF_MATCH_HL=y"

  # BBR TCP Congestion Control
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_ADVANCED=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_BBR=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_NET_SCH_FQ=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_BIC=n"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_WESTWOOD=n"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_HTCP=n"

  # IPSet support
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_MAX=256"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_BITMAP_IP=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_BITMAP_IPMAC=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_BITMAP_PORT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_IP=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_IPPORT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_IPPORTIP=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_IPPORTNET=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_NET=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_NETNET=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_NETPORT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_NETIFACE=y"

  # Compiler/cache preferences
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CCACHE=y"

  log_info "Kernel config updated"
}

# ---------- Build prep ----------
prepare_build() {
  log_step "Preparing build"
  sed -i '/# Check for uncommitted changes\./,/fi/d' ./scripts/setlocalversion || log_warn "setlocalversion not modified"
  sed -i '2s/check_defconfig//' ./build.config.gki 2>/dev/null || true

  case "$BUILD_CLEAN" in
    always) rm -rf "$OUT_DIR" && log_info "OUT_DIR cleared" ;;
    never)  log_info "Reusing OUT_DIR: $OUT_DIR" ;;
    auto)
      if [[ -d "$OUT_DIR" ]]; then
        log_warn "OUT_DIR exists: $OUT_DIR (reusing)"
      fi
      ;;
    *) log_warn "Unknown BUILD_CLEAN=$BUILD_CLEAN; reusing OUT_DIR" ;;
  esac
  mkdir -p "$OUT_DIR"
}

# ---------- Compile ----------
compile_kernel() {
  log_step "Compiling kernel"
  local start=$(date +%s)
  time make -j"$THREADS" \
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
    gki_defconfig all

  local end=$(date +%s); log_info "Compiled in $((end-start))s"
  [[ -f "$OUT_DIR/arch/arm64/boot/Image" ]] || { log_error "Image missing"; exit 1; }
}

# ---------- Package ----------
package_kernel() {
  log_step "Packaging"
  cd ..
  local image="$KERNEL_DIR/$OUT_DIR/arch/arm64/boot/Image"
  [[ -f "$image" ]] || { log_error "Kernel image not found: $image"; exit 1; }

  cp -fv "$image" "$ANYKERNEL_DIR"/
  (cd "$ANYKERNEL_DIR"; rm -rf .git; )

  local BUILD_LABEL; BUILD_LABEL="$(compose_label)"
  local zip_name="${ZIP_PREFIX}-${BUILD_LABEL}-${BUILD}.zip"
  (cd "$ANYKERNEL_DIR" && zip -r "../$zip_name" ./*)

  mkdir -p "$BUILDS_DIR"
  mv -v "$zip_name" "$BUILDS_DIR"/
  rm -f "$ANYKERNEL_DIR/Image"
  log_info "Output: $BUILDS_DIR/$zip_name"
}

main() {
  log_step "Start"
  validate_requirements
  setup_repositories
  setup_compiler
  prepare_kernel_source
  configure_pixel8a
  configure_lto
  install_kernelsu
  derive_build_from_kernelsu
  add_bbg
  apply_susfs_patches
  apply_additional_patches
  configure_kernel
  prepare_build
  compile_kernel
  package_kernel
  log_info "Build completed 🎉"
}

main "$@"

