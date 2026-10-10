#!/usr/bin/env bash
#
# One-shot Evolution X build for the Advan Tab V8 / Alldocube iPlay 60 mini Pro (T812).
#
#   ./evox/build.sh                 # Evolution X bka (Android 16 QPR2), GApps, userdebug
#   ./evox/build.sh --branch cnb    # Evolution X cnb (Android 17)
#   ./evox/build.sh --help          # all options
#
# The script syncs Evolution X plus the T812 device/vendor/kernel trees from
# evox/manifests/<branch>.xml, checks the synced trees, builds with
# `m evolution` and copies the flashable files to <dir>/release/<date>/.
#
# The kernel is NOT built: the stock GKI 5.10 image and vendor modules from
# device/advan/T812-kernel are used as prebuilts.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"
EVO_MANIFEST_URL="https://github.com/Evolution-X/manifest"
REPO_URL="https://storage.googleapis.com/git-repo-downloads/repo"
DEVICE="T812"

# ---------------------------------------------------------------- defaults ---
BRANCH="bka"
SRC_DIR=""
BUILD_TYPE="userdebug"
JOBS=""
WITH_GMS="true"
USE_LATEST=0
INSTALL_DEPS=0
DO_SYNC=1
DO_BUILD=1
DO_CLEAN=0
SHALLOW=1
CCACHE_SIZE="50G"
USE_CCACHE=1
FORCE=0

# ----------------------------------------------------------------- helpers ---
if [[ -t 1 ]]; then
    C_INFO=$'\e[1;34m' C_WARN=$'\e[1;33m' C_ERR=$'\e[1;31m' C_OK=$'\e[1;32m' C_OFF=$'\e[0m'
else
    C_INFO="" C_WARN="" C_ERR="" C_OK="" C_OFF=""
fi
info() { echo "${C_INFO}==>${C_OFF} $*"; }
ok()   { echo "${C_OK}  ok${C_OFF} $*"; }
warn() { echo "${C_WARN}warning:${C_OFF} $*" >&2; }
die()  { echo "${C_ERR}error:${C_OFF} $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Build options:
  -b, --branch NAME     Evolution X branch: bka (Android 16 QPR2, default)
                        or cnb (Android 17, early bring-up)
  -d, --dir DIR         source/build directory (default: ~/evox-<branch>)
  -t, --type TYPE       user | userdebug | eng (default: userdebug)
  -j, --jobs N          parallel jobs for sync and build (default: picked from CPU/RAM)
      --vanilla         build without GApps (WITH_GMS=false)
      --clean           run 'm installclean' before building

Sync options:
      --latest          use the newest commits of the T812 trees instead of
                        the pinned, cross-checked ones
      --full-history    full git history instead of --depth=1 (needs ~2x disk)
      --no-sync         skip repo init/sync, build what is already there
      --sync-only       sync and verify, do not build

Host options:
      --install-deps    install build dependencies with apt (Debian/Ubuntu, uses sudo)
      --ccache SIZE     ccache size (default: 50G)
      --no-ccache       do not use ccache
      --force           continue even if disk/RAM checks fail
  -h, --help            show this help
EOF
}

# ----------------------------------------------------------------- options ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--branch)    BRANCH="${2:?}"; shift 2 ;;
        -d|--dir)       SRC_DIR="${2:?}"; shift 2 ;;
        -t|--type)      BUILD_TYPE="${2:?}"; shift 2 ;;
        -j|--jobs)      JOBS="${2:?}"; shift 2 ;;
        --vanilla)      WITH_GMS="false"; shift ;;
        --clean)        DO_CLEAN=1; shift ;;
        --latest)       USE_LATEST=1; shift ;;
        --full-history) SHALLOW=0; shift ;;
        --no-sync)      DO_SYNC=0; shift ;;
        --sync-only)    DO_BUILD=0; shift ;;
        --install-deps) INSTALL_DEPS=1; shift ;;
        --ccache)       CCACHE_SIZE="${2:?}"; shift 2 ;;
        --no-ccache)    USE_CCACHE=0; shift ;;
        --force)        FORCE=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "unknown option: $1" ;;
    esac
done

case "$BRANCH" in
    bka) RELEASE="bp4a"; ANDROID="16 QPR2" ;;
    cnb) RELEASE="cp2a"; ANDROID="17" ;;
    *)   die "unsupported branch '$BRANCH' (use bka or cnb)" ;;
esac
case "$BUILD_TYPE" in
    user|userdebug|eng) ;;
    *) die "unsupported build type '$BUILD_TYPE'" ;;
esac
[[ -f "${MANIFEST_DIR}/${BRANCH}.xml" ]] || die "missing ${MANIFEST_DIR}/${BRANCH}.xml"

SRC_DIR="${SRC_DIR:-${HOME}/evox-${BRANCH}}"
LUNCH_TARGET="lineage_${DEVICE}-${RELEASE}-${BUILD_TYPE}"

# ------------------------------------------------------------- host checks ---
install_deps() {
    command -v apt-get >/dev/null || die "--install-deps supports only Debian/Ubuntu (apt-get)"
    info "Installing build dependencies (sudo)"
    sudo apt-get update
    sudo apt-get install -y \
        bc bison build-essential ccache curl flex g++-multilib gcc-multilib git git-lfs \
        gnupg gperf imagemagick lib32readline-dev lib32z1-dev libdw-dev libelf-dev \
        libsdl1.2-dev libssl-dev libxml2 libxml2-utils lz4 lzop pngcrush \
        protobuf-compiler python3 python3-protobuf python-is-python3 rsync schedtool \
        squashfs-tools unzip xsltproc zip zlib1g-dev
    # Not present on every release (e.g. Ubuntu 24.04 dropped ncurses5).
    local p
    for p in lib32ncurses-dev libncurses5 libncurses5-dev libncurses6; do
        sudo apt-get install -y "$p" >/dev/null 2>&1 || true
    done
    git lfs install --skip-repo >/dev/null
}

ensure_repo_tool() {
    if command -v repo >/dev/null; then
        REPO_BIN="$(command -v repo)"
        return
    fi
    REPO_BIN="${HOME}/.local/bin/repo"
    if [[ ! -x "$REPO_BIN" ]]; then
        info "Downloading the repo tool to ${REPO_BIN}"
        mkdir -p "$(dirname "$REPO_BIN")"
        curl -fsSL "$REPO_URL" -o "$REPO_BIN"
        chmod +x "$REPO_BIN"
    fi
}

host_checks() {
    info "Checking the host"
    [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] \
        || die "Android can only be built on x86_64 Linux"

    local missing=() t
    for t in git python3 curl git-lfs zip unzip; do
        command -v "$t" >/dev/null || missing+=("$t")
    done
    ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]} (re-run with --install-deps)"
    git lfs version >/dev/null 2>&1 || die "git-lfs is installed but not working"
    ensure_repo_tool
    ok "tools: git, python3, git-lfs, repo (${REPO_BIN})"

    local mem_gb swap_gb cpus
    mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    swap_gb=$(awk '/SwapTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    cpus=$(nproc)
    if ((mem_gb + swap_gb < 32)); then
        warn "RAM ${mem_gb}G + swap ${swap_gb}G is below 32G; the build will likely be killed."
        warn "Add swap (e.g. 'sudo fallocate -l 32G /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile')."
        ((FORCE)) || die "not enough memory (use --force to try anyway)"
    else
        ok "memory: ${mem_gb}G RAM + ${swap_gb}G swap, ${cpus} CPUs"
    fi

    if [[ -z "$JOBS" ]]; then
        # Roughly 2 GB of RAM per job keeps the linkers and metalava from OOMing.
        JOBS=$(( mem_gb / 2 ))
        ((JOBS > cpus)) && JOBS=$cpus
        ((JOBS < 1)) && JOBS=1
    fi
    ok "jobs: ${JOBS}"

    mkdir -p "$SRC_DIR"
    local need_gb free_gb
    need_gb=$(( SHALLOW ? 300 : 450 ))
    free_gb=$(df -P -BG "$SRC_DIR" | awk 'NR==2 {gsub("G","",$4); print $4}')
    # Space already used by an existing checkout counts towards the requirement.
    if [[ -d "${SRC_DIR}/.repo" ]]; then
        need_gb=$(( need_gb / 3 ))
    fi
    if ((free_gb < need_gb)); then
        warn "only ${free_gb}G free in ${SRC_DIR}, about ${need_gb}G is needed"
        ((FORCE)) || die "not enough disk space (use --force to try anyway)"
    else
        ok "disk: ${free_gb}G free in ${SRC_DIR}"
    fi
}

# -------------------------------------------------------------------- sync ---
install_local_manifest() {
    local dst="${SRC_DIR}/.repo/local_manifests"
    mkdir -p "$dst"
    # Drop manifests left behind by another branch of this script.
    rm -f "${dst}/T812.xml" "${dst}/roomservice.xml"
    if ((USE_LATEST)); then
        info "Using the newest commits of the T812 trees (--latest)"
        python3 -I - "${MANIFEST_DIR}/${BRANCH}.xml" "${dst}/T812.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
tree = ET.parse(sys.argv[1])
for p in tree.getroot().iter("project"):
    up = p.get("upstream")
    if up:
        p.set("revision", up)
tree.write(sys.argv[2], encoding="UTF-8", xml_declaration=True)
PY
    else
        cp "${MANIFEST_DIR}/${BRANCH}.xml" "${dst}/T812.xml"
    fi
    ok "local manifest: ${dst}/T812.xml"
}

sync_sources() {
    cd "$SRC_DIR"
    local init_args=(-u "$EVO_MANIFEST_URL" -b "$BRANCH" --git-lfs --no-clone-bundle)
    ((SHALLOW)) && init_args+=(--depth=1)

    info "repo init: Evolution X ${BRANCH} (Android ${ANDROID})"
    "$REPO_BIN" init "${init_args[@]}"
    install_local_manifest

    # Fails early on duplicate paths or bad revisions before downloading ~100 GB.
    "$REPO_BIN" manifest -o /dev/null || die "the merged manifest is invalid"

    local attempt
    for attempt in 1 2 3; do
        info "repo sync (attempt ${attempt}/3)"
        if "$REPO_BIN" sync -c -j"$JOBS" --force-sync --no-clone-bundle --no-tags \
                --optimized-fetch --prune --retry-fetches=3; then
            return
        fi
        warn "repo sync failed, retrying"
        sleep $((attempt * 30))
    done
    die "repo sync failed 3 times"
}

# ------------------------------------------------------------------ verify ---
verify_tree() {
    info "Verifying the T812 trees"
    cd "$SRC_DIR"
    local p
    for p in device/advan/T812 device/advan/T812-kernel vendor/advan/T812 \
             vendor/mediatek/ims hardware/mediatek device/mediatek/sepolicy_vndr \
             vendor/lineage build/make; do
        [[ -d "$p" ]] || die "missing ${p} after sync"
    done
    [[ -f "device/advan/T812/lineage_${DEVICE}.mk" ]] || die "missing lineage_${DEVICE}.mk"
    [[ -d "vendor/lineage/release/aconfig/${RELEASE}" ]] \
        || die "vendor/lineage has no '${RELEASE}' release; wrong Evolution X branch?"

    # A missing git-lfs object leaves a small text pointer instead of the binary.
    if grep -rIq --exclude-dir=.git "^version https://git-lfs.github.com/spec" \
            device/advan vendor/advan vendor/mediatek/ims 2>/dev/null; then
        info "Fetching missing git-lfs objects"
        for p in device/advan/T812 device/advan/T812-kernel vendor/advan/T812 vendor/mediatek/ims; do
            git -C "$p" lfs pull
        done
    fi

    python3 -I - "$SRC_DIR" <<'PY' || die "tree verification failed"
import os, re, sys

root = sys.argv[1]
errors = []

def check(path, what):
    if not os.path.exists(os.path.join(root, path)):
        errors.append(f"{what}: {path}")

# Prebuilt kernel: image, dtb, dtbo and every module listed in modules.load*.
kernel = "device/advan/T812-kernel"
for f in ("Image.gz", "dtbo.img", "dtb/mt6789.dtb"):
    check(f"{kernel}/{f}", "kernel")
for part, lists in (("vendor_ramdisk", ("modules.load", "modules.load.recovery")),
                    ("vendor_dlkm", ("modules.load",))):
    for lst in lists:
        lp = os.path.join(root, kernel, "modules", part, lst)
        if not os.path.exists(lp):
            errors.append(f"kernel: {kernel}/modules/{part}/{lst}")
            continue
        for ko in open(lp).read().split():
            check(f"{kernel}/modules/{part}/{ko}", "kernel module")

# Proprietary blobs referenced by the generated vendor makefiles.
vendor = "vendor/advan/T812"
mk = open(os.path.join(root, vendor, f"T812-vendor.mk")).read()
for src in re.findall(r"(vendor/advan/T812/proprietary/\S+?):", mk):
    check(src, "blob")
bp = open(os.path.join(root, vendor, "Android.bp")).read()
for block in re.findall(r"srcs:\s*\[([^\]]*)\]", bp):
    for src in re.findall(r'"([^"]+)"', block):
        check(f"{vendor}/{src}", "blob")

# Soong namespaces the device tree asks for.
dmk = open(os.path.join(root, "device/advan/T812/device.mk")).read()
m = re.search(r"PRODUCT_SOONG_NAMESPACES \+= \\\n((?:\s+\S+(?: \\)?\n)+)", dmk)
for ns in re.findall(r"^\s+(\S+?)(?: \\)?$", m.group(1) if m else "", re.M):
    if ns.startswith("$("):
        continue
    check(ns, "soong namespace")

if errors:
    print("\n".join(errors[:50]))
    if len(errors) > 50:
        print(f"... and {len(errors) - 50} more")
    sys.exit(1)
print("  T812 trees look complete")
PY
    ok "device, vendor blobs and prebuilt kernel are complete"
}

# ------------------------------------------------------------------- build ---
build() {
    cd "$SRC_DIR"
    export WITH_GMS
    export EVO_BUILD_TYPE="${EVO_BUILD_TYPE:-Unofficial}"
    if ((USE_CCACHE)); then
        export USE_CCACHE=1 CCACHE_EXEC
        CCACHE_EXEC="$(command -v ccache || true)"
        if [[ -n "$CCACHE_EXEC" ]]; then
            export CCACHE_DIR="${CCACHE_DIR:-${HOME}/.ccache}"
            ccache -M "$CCACHE_SIZE" >/dev/null
            ok "ccache: ${CCACHE_DIR} (${CCACHE_SIZE})"
        else
            warn "ccache not found, building without it"
            unset USE_CCACHE CCACHE_EXEC
        fi
    fi

    mkdir -p out
    local log
    log="out/build-${DEVICE}-${BRANCH}-$(date +%Y%m%d-%H%M).log"
    info "Building ${LUNCH_TARGET} (GApps: ${WITH_GMS}), log: ${SRC_DIR}/${log}"

    # envsetup.sh and lunch are not written for 'set -u' / 'set -e'.
    set +eu
    # shellcheck disable=SC1091
    source build/envsetup.sh
    lunch "$LUNCH_TARGET" || die "lunch ${LUNCH_TARGET} failed"
    if ((DO_CLEAN)); then
        m installclean || die "m installclean failed"
    fi
    m evolution -j"$JOBS" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    set -eu
    ((rc == 0)) || die "build failed (exit ${rc}); see ${SRC_DIR}/${log}"
}

collect() {
    local out="${SRC_DIR}/out/target/product/${DEVICE}"
    local zip="" z
    for z in "${out}"/EvolutionX-*.zip; do
        [[ -f "$z" && ( -z "$zip" || "$z" -nt "$zip" ) ]] && zip="$z"
    done
    [[ -n "$zip" ]] || die "build finished but no EvolutionX-*.zip found in ${out}"

    local rel f
    rel="${SRC_DIR}/release/$(date +%Y%m%d-%H%M)"
    mkdir -p "$rel"
    cp "$zip" "$rel/"
    for f in boot.img vendor_boot.img dtbo.img vbmeta.img; do
        [[ -f "${out}/${f}" ]] && cp "${out}/${f}" "$rel/"
    done
    (cd "$rel" && sha256sum -- * > SHA256SUMS)

    info "Done. Files for flashing are in ${rel}:"
    ls -lh "$rel"
    echo
    echo "First install (bootloader unlocked, from fastboot):"
    echo "  fastboot flash boot boot.img && fastboot flash vendor_boot vendor_boot.img"
    echo "  fastboot flash dtbo dtbo.img && fastboot flash vbmeta vbmeta.img"
    echo "  fastboot reboot recovery   # then: Factory reset -> Apply update -> adb sideload $(basename "$zip")"
}

# -------------------------------------------------------------------- main ---
info "T812 Evolution X build: branch ${BRANCH} (Android ${ANDROID}), ${BUILD_TYPE}, GApps: ${WITH_GMS}"
info "Source directory: ${SRC_DIR}"
((INSTALL_DEPS)) && install_deps
host_checks
((DO_SYNC)) && sync_sources
[[ -d "${SRC_DIR}/.repo" ]] || die "${SRC_DIR} is not a synced tree (drop --no-sync)"
verify_tree
if ((DO_BUILD)); then
    build
    collect
else
    info "Sync finished, build skipped (--sync-only)"
fi
