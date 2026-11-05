#!/bin/bash
# Build the SteamOS boot menu for the Lenovo Legion Y700 Gen 4 (TB322FC): the
# menu runtime (kShimC.bin, 4 MiB), the aarch64 packer tools and the install
# script, as one test bundle.
#
#   build-kshimc.sh [OUT_DIR]        default /work/kshimc-gen4
#
# Run it in the build VM. It starts an ubuntu:24.04 container itself (docker
# needed); the sources are fetched at the commits in
# external-and-mods/kshimc/pins.env, patched, built and tested there.
# Scratch (about 2 GB) goes to $KSHIMC_WORK, default /work/kshimc.
# KSHIMC_SKIP=host-tests leaves the (slow) host tests out while working on the rest.
#
# Checks: the runtime is exactly 4 MiB with no undefined symbols, the font has
# every glyph of the menu text, the host tests and the manifest tests in QEMU
# pass, the packer tools pass their own tests, and the image names no other OS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MOD="$REPO/external-and-mods/kshimc"
OUT="${1:-${KSHIMC_OUT:-/work/kshimc-gen4}}"
WORK="${KSHIMC_WORK:-/work/kshimc}"

IMAGE=steamos-kshimc-build:2
if [[ -z ${KSHIMC_INNER:-} ]]; then
  command -v docker >/dev/null || { echo "build-kshimc: docker is needed (run this in the build VM)" >&2; exit 1; }
  mkdir -p "$WORK" "$OUT"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> build image ($IMAGE)"
    docker build -q -t "$IMAGE" - <<'DOCKERFILE'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    git ca-certificates curl cmake ninja-build make build-essential \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    python3 python3-venv python3-pip device-tree-compiler qemu-system-arm \
    binutils file shellcheck xz-utils libasan8 libubsan1 ipxe-qemu \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE
  fi
  exec docker run --rm \
    -v "$REPO:/repo:ro" -v "$WORK:/w" -v "$(readlink -f "$OUT"):/out" \
    -e KSHIMC_INNER=1 -e JOBS="${JOBS:-4}" -e KSHIMC_SKIP="${KSHIMC_SKIP:-}" \
    "$IMAGE" bash /repo/scripts/build-kshimc.sh /out
fi

# --- inside the container --------------------------------------------------
OUT=/out WORK=/w MOD=/repo/external-and-mods/kshimc
JOBS="${JOBS:-4}"
die() { echo "build-kshimc: $*" >&2; exit 1; }
log() { echo "==> $*"; }
source "$MOD/pins.env"

mkdir -p "$WORK/cache" "$WORK/build"
fetch() {  # fetch URL COMMIT DIR [sparse paths...]: a shallow checkout of one commit
  local url=$1 commit=$2 dir=$3; shift 3
  if [[ -d $dir/.git && $(git -C "$dir" rev-parse HEAD 2>/dev/null) == "$commit" ]]; then return; fi
  [[ ! -e $dir ]] || die "$dir exists with another commit; remove it"
  git init -q "$dir"
  git -C "$dir" remote add origin "$url"
  if (( $# )); then
    git -C "$dir" config core.sparseCheckout true
    printf '%s\n' "$@" >"$dir/.git/info/sparse-checkout"
    git -C "$dir" fetch -q --depth=1 --filter=blob:none origin "$commit"
  else
    git -C "$dir" fetch -q --depth=1 origin "$commit"
  fi
  git -C "$dir" checkout -q --detach FETCH_HEAD
  [[ $(git -C "$dir" rev-parse HEAD) == "$commit" ]] || die "$url: wrong commit"
}

log "sources"
fetch "$KSHIMC_REPO_URL" "$KSHIMC_REPO_COMMIT" "$WORK/cache/repo" "$KSHIMC_SRC_PATH" "$KSHIMC_TOOLS_PATH"
fetch "$CRDK_URL" "$CRDK_COMMIT" "$WORK/cache/crdk"
fetch "$PICOLIBC_URL" "$PICOLIBC_COMMIT" "$WORK/cache/picolibc"
fetch "$LVGL_URL" "$LVGL_COMMIT" "$WORK/cache/lvgl"
fetch "$LIBFDT_URL" "$LIBFDT_COMMIT" "$WORK/cache/libfdt-src"

K="$WORK/build/src"
rm -rf "$K"
mkdir -p "$K"
cp -a "$WORK/cache/repo/$KSHIMC_SRC_PATH/." "$K/"
mkdir -p "$K/lib" "$K/third_party"
ln -s "$WORK/cache/crdk" "$K/lib/CrDK"
ln -s "$WORK/cache/picolibc" "$K/lib/picolibc"
ln -s "$WORK/cache/lvgl" "$K/third_party/lvgl"
git -C "$WORK/cache/libfdt-src" archive "$LIBFDT_COMMIT" lib/libfdt | tar -x -C "$K"
sed -i '/^#include <stdint.h>$/a #include <stdlib.h>' "$K/lib/libfdt/include/libfdt_env.h"
echo "$LIBFDT_ENV_SHA256  $K/lib/libfdt/include/libfdt_env.h" | sha256sum -c --quiet \
  || die "libfdt_env.h doesn't match its recorded hash"
# The CrDK patch hashes are for LF line endings.
sed -i 's/\r$//' "$K/ports/crdk/patches/"*.patch

log "patches"
: >"$K/.removed-names"
for p in "$MOD"/patches/*.py; do python3 "$p" "$K"; done
cp "$MOD/steamos_elden_defconfig" "$K/configs/steamos_elden_defconfig"
sort -u "$K/.removed-names" -o "$K/.removed-names"
[[ -s $K/.removed-names ]] || die "the patches recorded no removed names"

log "python tools"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q $PIP_PACKAGES
export PATH="$WORK/venv/bin:$PATH"
command -v genconfig >/dev/null || die "genconfig (kconfiglib) missing"

log "menu font: every glyph of the menu text"
python3 "$MOD/check-font-glyphs.py" "$K" "$WORK/build/menu-required-text" --write \
  || die "the font subset lacks glyphs for the menu text (regenerate it with tools/gen_ui_font.py --required-text)"
cmp -s "$WORK/build/menu-required-text" "$MOD/menu-required-text" \
  || die "external-and-mods/kshimc/menu-required-text is out of date: copy $WORK/build/menu-required-text over it"

log "runtime (steamos_elden_defconfig)"
RT="$WORK/build/runtime"
rm -rf "$RT"
(cd "$K" && python3 tools/build_runtime.py --config configs/steamos_elden_defconfig --out "$RT" --jobs "$JOBS")
[[ $(stat -c %s "$RT/kShimC.bin") == 4194304 ]] || die "kShimC.bin is not 4 MiB"
[[ -z $(aarch64-linux-gnu-nm -u "$RT/kShimC.elf") ]] || die "undefined symbols"
# No storage code in the runtime.
grep -q '^CONFIG_KSHIM_UFS' "$RT/.config" && die "UFS options are on in the build"
strings -a "$RT/kShimC.bin" >"$WORK/build/runtime-strings.txt"
while read -r w; do
  [[ -n $w ]] || continue
  if grep -qi -- "$w" "$WORK/build/runtime-strings.txt"; then die "the image still names a removed word ($w)"; fi
done <"$K/.removed-names"
grep -q 'SteamOS' "$WORK/build/runtime-strings.txt" || die "no SteamOS in the image"

skip() { [[ " ${KSHIMC_SKIP:-} " == *" $1 "* ]]; }
# These fail the same way on the untouched source in this build environment
# (aarch64 host, STAR_CHART): menu timing asserts in lvgl/menu_modern, and the
# MMU and reservation tests run x86-host assumptions on an aarch64 CPU.
KNOWN_HOST_FAILS="lvgl_test lvgl_hdk_test menu_modern_test mmu_test reserved_placeholder_test"

log "host tests"
HT="$WORK/build/host-tests"
if ! skip host-tests; then
  rm -rf "$HT"
  # GCC 13 reports truncation in a test's own snprintf as an error; not ours to change.
  cmake -S "$K/tests" -B "$HT" -G Ninja -DKSHIM_TEST_MENU_STYLE=STAR_CHART \
    -DCMAKE_C_FLAGS="-Wno-error=format-truncation" >"$WORK/build/host-configure.log" 2>&1 \
    || { tail -30 "$WORK/build/host-configure.log"; die "host tests: configure failed"; }
  cmake --build "$HT" -j "$JOBS" -- -k 0 >"$WORK/build/host-build.log" 2>&1 \
    || { grep -E "FAILED|error" "$WORK/build/host-build.log" | head -30; die "host tests: build failed"; }
  (cd "$HT" && ctest --output-on-failure -j "$JOBS") >"$WORK/build/host-ctest.log" 2>&1 || true
  grep -E 'tests passed|tests failed|Total Test time' "$WORK/build/host-ctest.log"
  failed=$(sed -n 's/^[[:space:]]*[0-9][0-9]* - \([A-Za-z0-9_]*\) (.*/\1/p' "$WORK/build/host-ctest.log" | sort)
  unexpected=$(comm -23 <(printf '%s\n' "$failed") <(printf '%s\n' $KNOWN_HOST_FAILS | sort))
  [[ -z $unexpected ]] || { echo "failed host tests: $unexpected"; die "host tests failed"; }
  echo "host tests: every failure is one of the known ones on the untouched source: $(echo $failed)"
else
  cmake -S "$K/tests" -B "$HT" -G Ninja -DKSHIM_TEST_MENU_STYLE=STAR_CHART -DCMAKE_C_FLAGS="-Wno-error=format-truncation" >/dev/null 2>&1
  cmake --build "$HT" -j "$JOBS" --target tb323fu_ui_preview >/dev/null 2>&1
fi

log "manifest tests in QEMU"
# The source's own tests look for the packer next to the source tree.
ln -sfn "$WORK/cache/repo/$KSHIMC_TOOLS_PATH/vendor/packer" "$WORK/build/MultiBootKernelPatcher"
# The device runtime has no QEMU platform: the tests use the QEMU profile of the same code.
(cd "$K" && python3 tools/build_runtime.py --config configs/qemu_manifest_serial_defconfig \
   --out "$WORK/build/runtime-qemu" --jobs "$JOBS") >"$WORK/build/runtime-qemu.log" 2>&1 \
  || { tail -20 "$WORK/build/runtime-qemu.log"; die "QEMU runtime build failed"; }
(cd "$K" && python3 tests/manifest_qemu.py --runtime "$WORK/build/runtime-qemu/kShimC.bin" --out "$WORK/build/qemu-manifest") \
  >"$WORK/build/qemu-manifest.log" 2>&1 || { tail -30 "$WORK/build/qemu-manifest.log"; die "QEMU manifest test failed"; }
tail -3 "$WORK/build/qemu-manifest.log"
(cd "$K" && python3 tests/manifest_ui_qemu.py --build "$WORK/build/qemu-manifest-ui") \
  >"$WORK/build/qemu-manifest-ui.log" 2>&1 || { tail -30 "$WORK/build/qemu-manifest-ui.log"; die "QEMU menu test failed"; }
tail -3 "$WORK/build/qemu-manifest-ui.log"

log "packer tools (aarch64, static)"
PT="$WORK/cache/repo/$KSHIMC_TOOLS_PATH"
rm -rf "$WORK/build/packer"
cmake -S "$PT/vendor/packer" -B "$WORK/build/packer" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHIMS=OFF -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc >"$WORK/build/packer-configure.log" 2>&1 \
  || { tail -20 "$WORK/build/packer-configure.log"; die "packer configure failed"; }
cmake --build "$WORK/build/packer" -j "$JOBS" >"$WORK/build/packer-build.log" 2>&1 \
  || { tail -20 "$WORK/build/packer-build.log"; die "packer build failed"; }
for t in MultiBootKernelPatcher UnpackTool; do
  readelf -h "$WORK/build/packer/$t" | grep -q 'Machine:[[:space:]]*AArch64' || die "$t is not aarch64"
  file "$WORK/build/packer/$t" | grep -q 'statically linked' || die "$t is not static"
done
for t in payload_from payload_from_nonbase dtb_alignment; do
  rm -rf "$WORK/build/packer-test-$t"
  python3 "$PT/vendor/packer/tests/$t.py" --packer "$WORK/build/packer/MultiBootKernelPatcher" \
    --unpacker "$WORK/build/packer/UnpackTool" --out "$WORK/build/packer-test-$t" >/dev/null \
    || die "packer test $t failed"
  echo "packer test $t: PASS"
done

log "menu screenshots (the real menu code, full resolution)"
SHOT="$WORK/build/menu-shots"
rm -rf "$SHOT"; mkdir -p "$SHOT"
"$HT/tb323fu_ui_preview" "$SHOT" --star-chart >"$SHOT/render.log" 2>&1 || { tail "$SHOT/render.log"; die "menu render failed"; }
python3 "$K/tools/preview_manifest.py" "$SHOT" >/dev/null

log "bundle"
rm -rf "${OUT:?}"/* 2>/dev/null || true
install -m 0644 "$RT/kShimC.bin" "$OUT/kShimC.bin"
install -m 0755 "$WORK/build/packer/MultiBootKernelPatcher" "$WORK/build/packer/UnpackTool" "$OUT/"
install -m 0755 "$PT/vendor/repack_boot_v4.py" "$PT/vendor/avbtool.py" "$OUT/"
for f in tablet-bootmenu-install tablet-bootmenu-pack tablet-slot; do
  install -m 0755 "/repo/steamos-overlay/usr/lib/steamos-arm/$f" "$OUT/$f"
done
install -m 0644 "$MOD/tester-README.txt" "$OUT/README.txt"
mkdir -p "$OUT/licenses" "$OUT/menu-preview"
cp "$PT/vendor/packer/LICENSE" "$OUT/licenses/packer-LICENSE"
cp "$PT/vendor/packer/lib/inih/LICENSE.txt" "$OUT/licenses/inih-LICENSE.txt"
cp "$K/LICENSE" "$OUT/licenses/kShimC-LICENSE"
cp "$K/src/ui/fonts/lxgw_wenkai_menu-OFL.txt" "$OUT/licenses/menu-font-OFL.txt"
cp "$SHOT"/*.png "$OUT/menu-preview/"
cat >"$OUT/BUILD-INFO.txt" <<INFO
kShimC.bin  4 MiB, GPL-3.0-only, built from $KSHIMC_REPO_URL
            commit $KSHIMC_REPO_COMMIT ($KSHIMC_SRC_PATH)
            with the changes in external-and-mods/kshimc/patches and steamos_elden_defconfig
sha256      $(sha256sum "$OUT/kShimC.bin" | cut -d' ' -f1)
INFO
(cd "$OUT" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort | xargs sha256sum >SHA256SUMS)
(cd "$OUT" && sha256sum -c --quiet SHA256SUMS) || die "SHA256SUMS check failed"
log "done: $OUT"
ls -la "$OUT"
