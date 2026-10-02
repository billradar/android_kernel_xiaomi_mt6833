#!/bin/bash

# Compile script for Aqua kernel

# Remove out directory
rm -rf out/arch/arm64/boot

# Prebuild hacks
rm -rf .config .config.old .tmp_versions
rm -rf include/generated include/config
rm -rf arch/arm64/include/generated
rm -rf vmlinux* System.map modules.builtin*
rm -f Module.symvers modules.order
rm -rf scripts/kconfig/.tmp*

# Date/Time
SECONDS=0
DATE=$(date '+%Y%m%d-%H%M')

# ReSukiSU release to integrate. Override this when building against another ref.
RESUKISU_REF="${RESUKISU_REF:-v4.2.0-rc3}"
JOBS="${JOBS:-$(nproc --all)}"

# Toolchain
TC_DIR="$HOME/toolchains/ZyC-clang-22.0.0"
CURRENT_DIR=$(pwd)

# Device Configs
DEVICE="everpal"
DEFCONFIG="${DEVICE}_defconfig"
ZIPNAME="AquaKernel-${DATE}.zip"

# Ensure the toolchain is available
HOST_ARCH=$(uname -m)
if [ "$HOST_ARCH" = "x86_64" ]; then
    if [ ! -x "$TC_DIR/bin/clang" ]; then
        mkdir -p "$TC_DIR" && cd "$TC_DIR" || exit
        wget -q https://github.com/ZyCromerZ/Clang/releases/download/22.0.0git-20250928-release/Clang-22.0.0git-20250928.tar.gz \
        && tar xf Clang-22.0.0git-20250928.tar.gz \
        && rm -f Clang-22.0.0git-20250928.tar.gz
        cd "$CURRENT_DIR" || exit
    fi
    export PATH="$TC_DIR/bin:$PATH"
else
    command -v clang >/dev/null 2>&1 || { echo "clang is required on $HOST_ARCH" >&2; exit 1; }
    command -v ld.lld >/dev/null 2>&1 || { echo "ld.lld is required on $HOST_ARCH" >&2; exit 1; }
    echo "Using native LLVM toolchain on $HOST_ARCH"
fi

export CC=clang
export LD=ld.lld

echo 
echo "Using compiler:"
clang --version
echo 

# Process options
CLEAN_BUILD=false
INCLUDE_KSU=false
REDO_KSU=false

for arg in "$@"; do
    case $arg in
        --clean)
            CLEAN_BUILD=true
            ;;
        --with-ksu)
            INCLUDE_KSU=true
            ;;
        --redo-ksu)
            INCLUDE_KSU=true
            REDO_KSU=true
            ;; 
    esac
done

# Perform clean build if specified
[ "$CLEAN_BUILD" = true ] && rm -rf out

mkdir -p out

if [ -f out/.ksu_applied ]; then
    echo "Including ReSukiSU $(cat out/.ksu_applied)!"
fi

# Include ReSukiSU if specified
if [[ "$INCLUDE_KSU" = true && ( ! -f out/.ksu_applied || "$(cat out/.ksu_applied)" != "$RESUKISU_REF" || "$REDO_KSU" = true ) ]]; then
    echo "Including ReSukiSU ${RESUKISU_REF}..."
    rm -f out/.ksu_applied

    # Re-running --redo-ksu should accept patches that are already present.
    apply_patch_once() {
        local patch_file="$1"

        if patch --dry-run --silent --forward --batch -p1 < "$patch_file"; then
            patch --batch --forward -p1 < "$patch_file"
        elif patch --dry-run --silent --reverse --batch -p1 < "$patch_file"; then
            echo "Already applied: $patch_file"
        else
            echo "Cannot apply patch: $patch_file" >&2
            return 1
        fi
    }

    # Stop here on a failed download or patch so an incomplete setup is never marked done.
    if ! (
        set -euo pipefail
        PATCH_TMP=$(mktemp -d)
        trap 'rm -rf "$PATCH_TMP" SU_patch' EXIT
        curl -fLSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/${RESUKISU_REF}/kernel/setup.sh" | bash -s -- "$RESUKISU_REF"
        git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git SU_patch
        for patch_script in SU_patch/Patches/*.sh; do
            bash "$patch_script"
        done
        patch_log="$PATCH_TMP/susfs_patch_to_4.14.log"
        if ! patch --dry-run --silent --forward --batch -p1 < SU_patch/Patches/Patch/susfs_patch_to_4.14.patch; then
            echo "The 4.14 SUSFS patch has known context overlaps; applying matching hunks non-interactively."
            patch --batch --forward -p1 < SU_patch/Patches/Patch/susfs_patch_to_4.14.patch > "$patch_log" 2>&1 || patch_status=$?
            cat "$patch_log"
            if [ "${patch_status:-0}" -gt 1 ]; then
                exit "$patch_status"
            fi
            if rg -q 'FAILED' "$patch_log" && ! rg -q 'fs/proc/task_mmu.c|fs/stat.c' "$patch_log"; then
                echo "Unexpected failure while applying the 4.14 SUSFS patch." >&2
                exit 1
            fi
        else
            apply_patch_once SU_patch/Patches/Patch/susfs_patch_to_4.14.patch
        fi
        curl -fLSs https://raw.githubusercontent.com/Addster09/EverpalPatches/main/KSUPatches/defconfig-Enable-KSU-and-SUSFS.patch -o "$PATCH_TMP/defconfig-Enable-KSU-and-SUSFS.patch"
        curl -fLSs https://raw.githubusercontent.com/Addster09/EverpalPatches/main/KSUPatches/susfs_patch_taskmmu.patch -o "$PATCH_TMP/susfs_patch_taskmmu.patch"
        apply_patch_once "$PATCH_TMP/defconfig-Enable-KSU-and-SUSFS.patch"
        apply_patch_once "$PATCH_TMP/susfs_patch_taskmmu.patch"
        apply_patch_once patches/resukisu-susfs-kstat-4.14.patch
        apply_patch_once patches/resukisu-sysread-4.14.patch
        rm -f fs/proc/task_mmu.c.rej fs/stat.c.rej
        rm -rf SU_patch
    ); then
        echo "ReSukiSU integration failed; fix the reported patch error before building." >&2
        exit 1
    fi
    printf '%s\n' "$RESUKISU_REF" > out/.ksu_applied
fi

# Compilation process
make O=out ARCH=arm64 "$DEFCONFIG"

if [ "$HOST_ARCH" = "aarch64" ]; then
    echo "Disabling Clang LTO for the native ARM64 toolchain."
    scripts/config --file out/.config --disable LTO_CLANG --enable LTO_NONE
    # This vendor 4.14 tree's compiler probe rejects stack protector flags
    # with current native Clang, so use its explicit no-protector config.
    scripts/config --file out/.config --disable CC_STACKPROTECTOR_STRONG --disable CC_STACKPROTECTOR_REGULAR --enable CC_STACKPROTECTOR_NONE
    make O=out ARCH=arm64 olddefconfig
fi

echo -e "\nStarting compilation...\n"

if \
	make -j"$JOBS" O=out \
	ARCH=arm64 \
	CC="ccache clang" \
	LLVM=1 \
	LLVM_IAS=1 \
	CROSS_COMPILE=aarch64-linux-gnu- \
	CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
	Image.gz dtbs; \
	then

    echo -e "\nKernel compiled successfully! Zipping up...\n"

    # Clone AnyKernel3 and create zip
    git clone -q --depth=1 https://github.com/Addster09/AnyKernel3 AnyKernel3
    cp out/arch/arm64/boot/Image.gz AnyKernel3
    (cd AnyKernel3 && zip -r9 "../$ZIPNAME" * -x '*.git*' README.md '*placeholder')
    rm -rf AnyKernel3 

    echo -e "\nCompleted in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)!"
    echo "Zip: $ZIPNAME"
else
    echo -e "\nCompilation failed!"
    exit 1
fi
