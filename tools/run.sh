#!/bin/sh
# run.sh - optional guest-side hook, staged onto the shared storage as
#          share/mali/run.sh and run by /init AFTER the module is loaded and
#          the mali_smoke test has been executed.
#
# Because it lives on the share (9p) / disk image (ext4), you can edit it on
# the host and re-run it in the guest without rebuilding the initramfs.
#
# Put your own experiments here: the Arm userspace DDK tools, Kbase ioctl
# probes, fuzzers, dmesg/log collection, ...
DIR="$(dirname "$0")"

echo "run.sh: /dev/mali0 -> $(ls -l /dev/mali0 2>&1 | sed 's/.* //')"
echo "run.sh: kernel DDK -> $(dmesg 2>/dev/null | sed -n 's/.*Kernel DDK version \([^ ]*\).*/\1/p' | tail -1)"

# Re-run the ioctl smoke test if you like:
# "$DIR/mali_smoke"

# Or drop a binary in the share and exec it:
# "$DIR/mytool"
