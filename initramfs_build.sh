#!/usr/bin/env bash
#
# initramfs_build.sh - build a bootable arm64 initramfs from scratch for the
#                      Arm GPU bug bounty virtual platform (QEMU virt, Mali
#                      "dummy model" via CONFIG_MALI_NO_MALI).
#
# It:
#   1. obtains a BusyBox source tarball (local copy first, else download),
#   2. cross-compiles BusyBox statically for arm64,
#   3. stages a minimal root filesystem (/init, /load_mod.sh, /getfile.sh),
#   4. optionally embeds the Kbase module as a fallback (BAKE_MODULE=1),
#   5. packages everything as a gzipped newc cpio image.
#
# The module and the test binaries normally come from the SHARED storage the
# launcher attaches (run_arm64.sh):
#     share/         -> guest /host   (9p)
#     out/shared.img -> guest /dev/vda (ext4)
# /init mounts both and loads mali_kbase.ko from there, so changing the module
# or a userspace test does not require rebuilding this initramfs.
#
# Normally run automatically by build.sh once the kernel + module build
# succeeds, but it also works standalone:
#
#   ./initramfs_build.sh                       # uses out/mali_kbase.ko
#   KO=path/to/mali_kbase.ko ./initramfs_build.sh
#
# Produces:
#   out/initramfs-arm64.cpio.gz
#
# Overridable environment variables:
#   ARCH               (default arm64; this image is arm64-only)
#   CROSS_COMPILE      (default aarch64-linux-gnu-)
#   JOBS               (default nproc)
#   KO                 module to embed (default <root>/out/mali_kbase.ko)
#   OUT                output image    (default <root>/out/initramfs-arm64.cpio.gz)
#   BUSYBOX_VERSION    (default 1.32.0)
#   BUSYBOX_BIN        use this prebuilt static busybox instead of compiling
#   BUSYBOX_REBUILD    1 to force recompiling busybox even if cached
#   BUSYBOX_SEED_DIR   dir searched for a local busybox source tarball
#   INITRAMFS_SHELL    1 = drop to a shell on boot, 0 = smoke-test + poweroff
#   BAKE_MODULE        0 = module comes from the shared storage (default)
#                      1 = also embed $KO as /mali_kbase.ko fallback
#   SMOKE_BIN          optional static aarch64 binary embedded as /mali_smoke
#
set -euo pipefail

ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"
BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.32.0}"
BUSYBOX_BIN="${BUSYBOX_BIN:-}"
BUSYBOX_REBUILD="${BUSYBOX_REBUILD:-0}"
INITRAMFS_SHELL="${INITRAMFS_SHELL:-1}"
BAKE_MODULE="${BAKE_MODULE:-0}"
SMOKE_BIN="${SMOKE_BIN:-}"
# Local checkout that already ships the BusyBox source tarball (optional).
BUSYBOX_SEED_DIR="${BUSYBOX_SEED_DIR:-/home/za0x/00-00/00-003/mali_models/initramfs}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DL="$ROOT/downloads"
BUILD="$ROOT/build"
ROOTFS="$BUILD/initramfs-root"
BSRC="$BUILD/busybox-${BUSYBOX_VERSION}"
KO="${KO:-$ROOT/out/mali_kbase.ko}"
OUT="${OUT:-$ROOT/out/initramfs-arm64.cpio.gz}"
BB_TARBALL="$DL/busybox-${BUSYBOX_VERSION}.tar.bz2"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$ARCH" = arm64 ] || fail "ARCH=$ARCH unsupported; this initramfs is arm64-only"

# ---------------------------------------------------------------------------
# [0/5] prerequisites + input module
# ---------------------------------------------------------------------------
for t in tar cpio gzip make file wget "${CROSS_COMPILE}gcc"; do
  command -v "$t" >/dev/null 2>&1 || fail "missing host tool: $t"
done
# The module is only needed inside the image when BAKE_MODULE=1; otherwise it
# is loaded from the shared storage (share/ + out/shared.img) at boot.
if [ "$BAKE_MODULE" = 1 ]; then
  [ -s "$KO" ] || fail "module not found: $KO
  build the kernel + driver first: ./build.sh"
fi

mkdir -p "$DL" "$BUILD" "$BUILD/logs" "$(dirname "$OUT")"

# ---------------------------------------------------------------------------
# [1/5] obtain BusyBox (prebuilt override -> compiled cache -> build from source)
# ---------------------------------------------------------------------------
is_static_arm64() { # <binary>
  local f
  f="$(file -b "$1" 2>/dev/null || true)"
  case "$f" in *aarch64*) ;; *) return 1;; esac
  case "$f" in *"statically linked"*) return 0;; *) return 1;; esac
}

if [ -z "$BUSYBOX_BIN" ]; then
  # a) reuse a previously compiled static BusyBox
  if [ "$BUSYBOX_REBUILD" = 0 ] && [ -x "$BSRC/busybox" ] && is_static_arm64 "$BSRC/busybox"; then
    BUSYBOX_BIN="$BSRC/busybox"
    log "[1/5] reusing compiled BusyBox ($BUSYBOX_BIN)"
  else
    # b) fetch the source tarball (local seed first)
    if [ ! -s "$BB_TARBALL" ]; then
      seed=""
      for c in "$BUSYBOX_SEED_DIR/busybox-${BUSYBOX_VERSION}.tar.bz2"; do
        [ -s "$c" ] && seed="$c" && break
      done
      if [ -n "$seed" ]; then
        log "[1/5] using local BusyBox source: $seed"
        cp -f "$seed" "$BB_TARBALL"
      else
        log "[1/5] downloading BusyBox $BUSYBOX_VERSION source"
        wget -q -O "$BB_TARBALL.part" \
          "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" \
          || { rm -f "$BB_TARBALL.part"; fail "could not fetch BusyBox source"; }
        mv "$BB_TARBALL.part" "$BB_TARBALL"
      fi
    fi
    # c) cross-compile a static arm64 BusyBox
    log "[2/5] cross-compiling BusyBox $BUSYBOX_VERSION (static, arm64)"
    rm -rf "$BSRC"; mkdir -p "$BSRC"
    tar -C "$BSRC" --strip-components=1 -xjf "$BB_TARBALL"
    make -C "$BSRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" defconfig >/dev/null
    sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' "$BSRC/.config"
    grep -q '^CONFIG_STATIC=y' "$BSRC/.config" || echo 'CONFIG_STATIC=y' >> "$BSRC/.config"
    # Newer host kernel headers dropped the CBQ qdisc enums used by the `tc`
    # applet; disable it so BusyBox compiles against modern headers.
    sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' "$BSRC/.config"
    make -C "$BSRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" LDFLAGS="-static" -j"$JOBS"
    BUSYBOX_BIN="$BSRC/busybox"
  fi
fi

is_static_arm64 "$BUSYBOX_BIN" \
  || fail "BusyBox is not a static aarch64 binary: $(file -b "$BUSYBOX_BIN" 2>/dev/null)"

# ---------------------------------------------------------------------------
# [3/5] stage a minimal root filesystem
# ---------------------------------------------------------------------------
log "[3/5] staging root filesystem in $ROOTFS"
rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"
mkdir -p "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" "$ROOTFS/tmp" "$ROOTFS/mnt" "$ROOTFS/etc"

if [ "$BUSYBOX_BIN" = "$BSRC/busybox" ]; then
  # Let BusyBox lay out its own applet symlinks. `make install` only reads the
  # build config; it does not execute the (arm64) binary, so it works on x86.
  make -C "$BSRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
       CONFIG_PREFIX="$ROOTFS" install >/dev/null
else
  # Prebuilt BusyBox override: create a sensible applet symlink set ourselves.
  mkdir -p "$ROOTFS/bin" "$ROOTFS/sbin" "$ROOTFS/usr/bin" "$ROOTFS/usr/sbin"
  for a in sh mount umount cat ls mkdir mknod chmod chown cp mv rm ln echo dmesg \
           grep sed awk tr cut head tail sort sleep sync wget kill ps free uname \
           date dd hexdump find xargs true false test pwd env printf vi more \
           insmod rmmod modprobe lsmod mdev poweroff halt reboot ifconfig route \
           ip setsid cttyhack; do
    ln -sf busybox "$ROOTFS/bin/$a"
  done
fi
[ -e "$ROOTFS/bin/busybox" ] || cp -f "$BUSYBOX_BIN" "$ROOTFS/bin/busybox"
chmod 0755 "$ROOTFS/bin/busybox"

# optionally bake the module + smoke test in (fallback when no share is attached)
if [ "$BAKE_MODULE" = 1 ]; then
  cp -f "$KO" "$ROOTFS/mali_kbase.ko"
fi
if [ -n "$SMOKE_BIN" ] && [ -s "$SMOKE_BIN" ]; then
  cp -f "$SMOKE_BIN" "$ROOTFS/mali_smoke"
  chmod 0755 "$ROOTFS/mali_smoke"
fi

cat > "$ROOTFS/init" <<'INIT'
#!/bin/sh
# Mali Kbase dummy-model boot init (CONFIG_MALI_NO_MALI).
#
# The driver + userspace tests are loaded from the SHARED storage when the
# launcher (run_arm64.sh) attaches it:
#     /host  <- 9p folder   share/          (mount_tag host0)
#     /mnt   <- ext4 image  out/shared.img  (/dev/vda)
# A module baked into this initramfs (/mali_kbase.ko) is only a fallback.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc     none /proc             2>/dev/null
mount -t sysfs    none /sys              2>/dev/null
mount -t devtmpfs none /dev              2>/dev/null
mount -t debugfs  none /sys/kernel/debug 2>/dev/null
mkdir -p /tmp && mount -t tmpfs none /tmp 2>/dev/null

# optional QEMU user-net (only needed by /getfile.sh)
ifconfig lo 127.0.0.1 up 2>/dev/null
ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null

echo "=== guest up: $(uname -r) $(uname -m)"
cat /proc/cmdline

# --- shared storage -------------------------------------------------------
mkdir -p /mnt /host
mount -t ext4 /dev/vda /mnt 2>/dev/null && echo "shared disk   : /dev/vda -> /mnt"
mount -t 9p -o trans=virtio,version=9p2000.L host0 /host 2>/dev/null \
  && echo "shared folder : host0 -> /host"

# prefer the live 9p share, then the ext4 image, then a baked fallback
MALI_BASE=""
for b in /host /mnt; do
  if [ -f "$b/mali/mali_kbase.ko" ]; then MALI_BASE="$b/mali"; break; fi
done

echo "=== loading mali_kbase.ko (NO_MALI dummy model) ==="
if [ -n "$MALI_BASE" ]; then
  echo "module source: $MALI_BASE/mali_kbase.ko"
  insmod "$MALI_BASE/mali_kbase.ko"
  echo "insmod rc=$?"
elif [ -f /mali_kbase.ko ]; then
  echo "module source: /mali_kbase.ko (baked-in fallback)"
  insmod /mali_kbase.ko
  echo "insmod rc=$?"
else
  echo "no Mali module on the shared storage or in this initramfs"
fi

dev="$(cat /sys/class/misc/mali0/dev 2>/dev/null)"
if [ -n "$dev" ]; then
  rm -f /dev/mali0
  mknod /dev/mali0 c "${dev%:*}" "${dev#*:}" 2>/dev/null || true
  chmod 0664 /dev/mali0 2>/dev/null || true
fi

echo "=== /dev/mali* ==="
ls -l /dev/mali* 2>&1

echo "=== mali dmesg ==="
dmesg | grep -iE 'mali|dummy model|Probed as mali0|Kernel DDK version|GPU identified' | tail -25

# --- mandatory userspace smoke test (from the shared storage) --------------
SMOKE=skip
for cand in "$MALI_BASE/mali_smoke" /mnt/mali/mali_smoke /host/mali/mali_smoke /mali_smoke; do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  echo "=== mali userspace smoke test ($cand) ==="
  "$cand"; SMOKE=$?
  break
done

# --- optional user hook (share/mali/run.sh) --------------------------------
if [ -n "$MALI_BASE" ] && [ -x "$MALI_BASE/run.sh" ]; then
  echo "=== extra: $MALI_BASE/run.sh ==="
  "$MALI_BASE/run.sh" || echo "run.sh rc=$?"
fi

echo "=== RESULT: probe=$(dmesg | grep -c 'Probed as mali0') smoke=$([ "$SMOKE" = 0 ] && echo PASS || echo "$SMOKE") ==="
INIT
if [ "$INITRAMFS_SHELL" = 1 ]; then
  cat >> "$ROOTFS/init" <<'INIT'
echo "=== dropping to interactive shell (run /load_mod.sh to (re)load the module) ==="
exec /bin/sh
INIT
else
  cat >> "$ROOTFS/init" <<'INIT'
echo "=== smoke test complete, powering off ==="
sync
poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
INIT
fi
chmod 0755 "$ROOTFS/init"

cat > "$ROOTFS/load_mod.sh" <<'SCRIPT'
#!/bin/sh
# Load the Mali Kbase module and (re)create /dev/mali0.
# Path-agnostic: uses /sys/class/misc/mali0, so it works whether the device
# tree node is gpu@c0000 (Kernel/README) or gpu@6e000000 (how-to guide).
KO="${1:-/mali_kbase.ko}"
rmmod mali_kbase 2>/dev/null
insmod "$KO" || exit 1
dev="$(cat /sys/class/misc/mali0/dev 2>/dev/null)"
if [ -n "$dev" ]; then
  rm -f /dev/mali0
  mknod /dev/mali0 c "${dev%:*}" "${dev#*:}" && chmod 0664 /dev/mali0
fi
ls -l /dev/mali0 2>&1
SCRIPT
chmod 0755 "$ROOTFS/load_mod.sh"

cat > "$ROOTFS/getfile.sh" <<'SCRIPT'
#!/bin/sh
# Fetch a file from the QEMU user-net host (10.0.2.2:8080) into the guest root.
# Run `python3 -m http.server 8080` in this directory on the host first.
[ -n "$1" ] || { echo "usage: $0 <file>"; exit 1; }
wget -q -O "/$1" "http://10.0.2.2:8080/$1" && chmod 0755 "/$1" && echo "fetched /$1"
SCRIPT
chmod 0755 "$ROOTFS/getfile.sh"

# ---------------------------------------------------------------------------
# [4/5] package the initramfs
# ---------------------------------------------------------------------------
log "[4/5] packaging $OUT"
( cd "$ROOTFS" && find . -print0 \
    | cpio --null -o -H newc --owner=0:0 2>/dev/null \
    | gzip -9 ) > "$OUT"
[ -s "$OUT" ] || fail "failed to create $OUT"

# ---------------------------------------------------------------------------
# [5/5] summary
# ---------------------------------------------------------------------------
{
  echo "initramfs : $OUT ($(stat -c%s "$OUT") bytes)"
  echo "busybox   : $BUSYBOX_BIN"
  echo "module    : $([ "$BAKE_MODULE" = 1 ] && echo "$KO (baked fallback)" || echo 'loaded from shared storage')"
  echo "init      : $([ "$INITRAMFS_SHELL" = 1 ] && echo 'interactive shell' || echo 'smoke-test + poweroff')"
} | tee "$BUILD/logs/initramfs.txt"
log "[5/5] done"
