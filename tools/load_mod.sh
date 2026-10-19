#!/bin/sh
# load_mod.sh - load mali_kbase.ko in the guest and (re)create /dev/mali0.
#
# Intended to run from the shared storage (9p /host or ext4 /mnt), so the
# default module path is the one next to this script:
#
#   /host/mali/load_mod.sh                 -> /host/mali/mali_kbase.ko
#   /mnt/mali/load_mod.sh /other/mali.ko   -> explicit module
#
# Path-agnostic about the device tree: the char-device major/minor are read
# from sysfs, so it also works with the Kernel/README node (gpu@c0000).
set -e
KO="${1:-$(dirname "$0")/mali_kbase.ko}"

[ -f "$KO" ] || { echo "load_mod.sh: no module at $KO" >&2; exit 1; }

rmmod mali_kbase 2>/dev/null || true
insmod "$KO" || exit 1

dev="$(cat /sys/class/misc/mali0/dev 2>/dev/null)"
if [ -n "$dev" ]; then
  rm -f /dev/mali0
  mknod /dev/mali0 c "${dev%:*}" "${dev#*:}" 2>/dev/null || true
  chmod 0664 /dev/mali0 2>/dev/null || true
fi

ls -l /dev/mali0 2>&1
