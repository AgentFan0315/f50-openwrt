#!/bin/bash
# Build sprd_wlan_combo (SC2355 Wi-Fi) as an external module against out-linux.
# Source: realme C51/C53 AndroidT kernel_modules/kernel5.4/wcn/wlan/wlan_combo (GPL), patched for the MU300.
set -e
WSRC=${WSRC:-/src/ext-wlan_combo}
# a patch either applies or is applied already; anything else stops the build (as upstream/build.sh)
cd "$WSRC" && for p in /work/patches/wlan_combo-*.patch; do
    if patch -p1 -N -s --dry-run < "$p" >/dev/null 2>&1; then patch -p1 -N -s < "$p"
    elif patch -p1 -R -s -f --dry-run < "$p" >/dev/null 2>&1; then :
    else echo "patch does not apply: $p" >&2; exit 1; fi
done
cd /src/zte-u30air
make O=/src/out-linux ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld -j"$(nproc)" M="$WSRC" modules
llvm-strip --strip-debug -o /src/out-linux/sprd_wlan_combo.ko "$WSRC/sprd_wlan_combo.ko"
