#!/usr/bin/env bash
#
# run_arm64.sh - boot the built arm64 kernel + initramfs under QEMU with the
#               Mali virtual platform, attaching the shared storage:
#
#                 out/shared.img  -> guest /dev/vda   (ext4, -drive)
#                 share/          -> guest /host       (9p,  -virtfs)
#
#               /init mounts both and loads mali_kbase.ko (+ mali_smoke) from
#               the shared storage, so no initramfs rebuild is needed to swap
#               the module or a test binary.
#
# Usage:
#   ./run_arm64.sh                # boot (builds the disk image if missing)
#   ./run_arm64.sh --gdb          # add -S -gdb tcp::12345
#   ./run_arm64.sh --disk-only    # do not attach the 9p share
#   ./run_arm64.sh --9p-only      # do not attach the ext4 image
#   ./run_arm64.sh --no-build     # never auto-build out/shared.img
#   ./run_arm64.sh -- <args...>   # append extra args to qemu
#
# Overridable environment:
#   OUT    (default <root>/out)
#   SHARE  (default <root>/share)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$ROOT/out}"
SHARE="${SHARE:-$ROOT/share}"
IMG="$OUT/shared.img"

GDB=0; USE_DISK=1; USE_9P=1; NO_BUILD=0
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --gdb)       GDB=1 ;;
    --disk-only) USE_9P=0 ;;
    --9p-only)   USE_DISK=0 ;;
    --no-build)  NO_BUILD=1 ;;
    --)          shift; EXTRA=("$@"); break ;;
    -h|--help)   sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

for f in "$OUT/Image.gz" "$OUT/initramfs-arm64.cpio.gz" "$OUT/virt_mali.dtb"; do
  [ -s "$f" ] || { printf 'ERROR: %s missing; run ./build.sh\n' "$f" >&2; exit 1; }
done

ARGS=(-machine virt -cpu cortex-a57 -smp 2 -m 4096 -nographic -net nic -net user)
[ "$GDB" = 1 ] && ARGS+=(-S -gdb tcp::12345)

if [ "$USE_DISK" = 1 ]; then
  if [ ! -s "$IMG" ] && [ "$NO_BUILD" != 1 ]; then
    printf '\033[1;34m==>\033[0m building the shared disk image (%s)\n' "$IMG"
    "$ROOT/disk.sh" build
  fi
  [ -s "$IMG" ] && ARGS+=(-drive "file=$IMG,format=raw,if=virtio")
fi

if [ "$USE_9P" = 1 ]; then
  mkdir -p "$SHARE"
  ARGS+=(-virtfs "local,path=$SHARE,mount_tag=host0,security_model=passthrough")
fi

ARGS+=(
  -kernel "$OUT/Image.gz"
  -initrd "$OUT/initramfs-arm64.cpio.gz"
  -dtb    "$OUT/virt_mali.dtb"
  -append 'console=ttyAMA0 rdinit=/init acpi=off nokaslr loglevel=7'
)
[ "${#EXTRA[@]}" -gt 0 ] && ARGS+=("${EXTRA[@]}")

set -x
exec qemu-system-aarch64 "${ARGS[@]}"
