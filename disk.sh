#!/usr/bin/env bash
#
# disk.sh - build and manage the shared ext4 disk image used to exchange files
#           between the host and the QEMU arm64 guest.
#
# The image is a plain raw ext4 filesystem. It is populated WITHOUT root from
# the share/ tree using `mkfs.ext4 -d`, and individual files can be added,
# extracted or removed with debugfs (also no root). The guest sees it as
# /dev/vda when it is attached with `-drive if=virtio` (see run_arm64.sh).
#
# Usage:
#   ./disk.sh build              # (re)build out/shared.img from share/
#   ./disk.sh ls                 # list the image root
#   ./disk.sh put  <file> [dst]  # copy a host file into the image
#   ./disk.sh get  <src> <dst>   # extract a file from the image
#   ./disk.sh rm   <path>        # delete a file/dir inside the image
#   ./disk.sh df                 # show filesystem usage
#   ./disk.sh fsck               # e2fsck -fy (clean the journal after a VM run)
#   ./disk.sh mount  [dir]       # optional: sudo loop-mount (default /mnt/malishare)
#   ./disk.sh umount [dir]       # optional: sudo umount
#
# Overridable environment:
#   IMG      disk image        (default <root>/out/shared.img)
#   SRC      staging tree      (default <root>/share)
#   SIZE_MB  image size in MiB (default 64)
#   LABEL    ext4 volume label (default MALISHARE)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="${IMG:-$ROOT/out/shared.img}"
SRC="${SRC:-$ROOT/share}"
SIZE_MB="${SIZE_MB:-64}"
LABEL="${LABEL:-MALISHARE}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cmd="${1:-}"
shift 2>/dev/null || true

case "$cmd" in

build)
  have mkfs.ext4 || fail "mkfs.ext4 not found (install e2fsprogs)"
  [ -d "$SRC" ] || fail "staging dir not found: $SRC"
  mkdir -p "$(dirname "$IMG")"
  log "creating $IMG (ext4, ${SIZE_MB} MiB, label $LABEL) from $SRC"
  rm -f "$IMG"
  truncate -s "${SIZE_MB}M" "$IMG"
  mkfs.ext4 -q -F -L "$LABEL" -d "$SRC" "$IMG"
  log "image ready: $IMG ($(stat -c%s "$IMG") bytes)"
  ;;

ls)
  have debugfs || fail "debugfs not found (install e2fsprogs)"
  [ -s "$IMG" ] || fail "no image: $IMG"
  debugfs -R "ls -l /" "$IMG" 2>/dev/null
  ;;

put)
  have debugfs || fail "debugfs not found (install e2fsprogs)"
  [ $# -ge 1 ] || fail "usage: disk.sh put <hostfile> [destpath]"
  hf="$1"; dst="${2:-/$(basename "$1")}"
  [ -s "$hf" ] || fail "no such file: $hf"
  [ -s "$IMG" ] || fail "no image: $IMG (run: ./disk.sh build)"
  debugfs -w -R "rm $dst" "$IMG" >/dev/null 2>&1 || true
  debugfs -w -R "write $hf $dst" "$IMG" >/dev/null 2>&1 || fail "debugfs write failed"
  log "put $hf -> $dst"
  ;;

get)
  have debugfs || fail "debugfs not found (install e2fsprogs)"
  [ $# -ge 2 ] || fail "usage: disk.sh get <path> <hostdest>"
  [ -s "$IMG" ] || fail "no image: $IMG"
  rm -f "$2"
  debugfs -R "dump $1 $2" "$IMG" >/dev/null 2>&1 || fail "could not extract $1"
  [ -s "$2" ] || fail "empty/missing extraction: $2"
  log "extracted $1 -> $2 ($(stat -c%s "$2") bytes)"
  ;;

rm)
  have debugfs || fail "debugfs not found (install e2fsprogs)"
  [ $# -ge 1 ] || fail "usage: disk.sh rm <path>"
  [ -s "$IMG" ] || fail "no image: $IMG"
  debugfs -w -R "rm $1" "$IMG" >/dev/null 2>&1 || fail "could not remove $1"
  log "removed $1"
  ;;

df)
  have dumpe2fs || fail "dumpe2fs not found (install e2fsprogs)"
  [ -s "$IMG" ] || fail "no image: $IMG"
  dumpe2fs -h "$IMG" 2>/dev/null \
    | grep -E 'Filesystem (state|volume)|Block (count|size)|Inode count'
  ;;

fsck)
  have e2fsck || fail "e2fsck not found (install e2fsprogs)"
  [ -s "$IMG" ] || fail "no image: $IMG"
  sudo e2fsck -fy "$IMG" || true
  ;;

mount)
  dir="${1:-/mnt/malishare}"
  [ -s "$IMG" ] || fail "no image: $IMG"
  sudo mkdir -p "$dir"
  sudo mount -o loop "$IMG" "$dir"
  log "mounted $IMG at $dir"
  ;;

umount)
  dir="${1:-/mnt/malishare}"
  sudo umount "$dir"
  log "unmounted $dir"
  ;;

""|-h|--help|help)
  sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
  ;;

*)
  fail "unknown command: $cmd (build|ls|put|get|rm|df|fsck|mount|umount)"
  ;;
esac
