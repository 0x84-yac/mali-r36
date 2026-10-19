/*
 * mali_smoke.c - minimal userspace smoke test for the Mali Kbase driver
 *                (/dev/mali0) on the Arm GPU bug bounty virtual platform.
 *
 * Cross-compile statically for the guest:
 *   aarch64-linux-gnu-gcc -static -O2 -Wall -o mali_smoke mali_smoke.c
 *
 * Checks:
 *   1. open("/dev/mali0", O_RDWR)                  [required]
 *   2. KBASE_IOCTL_VERSION_CHECK                    [required]
 *   3. KBASE_IOCTL_GET_GPUPROPS (size=0)            [informational]
 *   4. KBASE_IOCTL_SET_FLAGS                        [informational]
 *
 * Exits 0 only when the required checks pass. The ioctl numbers/sizes are
 * taken verbatim from the r36p0 UAPI headers
 *   include/uapi/gpu/arm/midgard/{,jm/}mali_kbase_ioctl.h
 * so no kernel headers are needed to build this.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define KBASE_IOCTL_TYPE 0x80

/* _IOWR(0x80, 0, struct kbase_ioctl_version_check) */
struct kbase_ioctl_version_check {
	uint16_t major;
	uint16_t minor;
};
#define KBASE_IOCTL_VERSION_CHECK \
	_IOWR(KBASE_IOCTL_TYPE, 0, struct kbase_ioctl_version_check)

/* _IOW(0x80, 1, struct kbase_ioctl_set_flags) */
struct kbase_ioctl_set_flags {
	uint32_t create_flags;
};
#define KBASE_IOCTL_SET_FLAGS \
	_IOW(KBASE_IOCTL_TYPE, 1, struct kbase_ioctl_set_flags)

/* _IOW(0x80, 3, struct kbase_ioctl_get_gpuprops) */
struct kbase_ioctl_get_gpuprops {
	uint64_t buffer;
	uint32_t size;
	uint32_t flags;
};
#define KBASE_IOCTL_GET_GPUPROPS \
	_IOW(KBASE_IOCTL_TYPE, 3, struct kbase_ioctl_get_gpuprops)

/* UAPI version the r36p0 driver speaks (BASE_UK_VERSION_MAJOR.MINOR) */
#define KBASE_UK_VERSION_MAJOR 11
#define KBASE_UK_VERSION_MINOR 34

static int required_failures;

static void report(const char *label, int required, int ok, int rc, int err)
{
	printf("  [%s] %-30s rc=%d errno=%d (%s)%s\n",
	       ok ? "PASS" : "FAIL", label, rc, err, strerror(err),
	       required ? "" : "  [info]");
	if (required && !ok)
		required_failures++;
}

int main(int argc, char **argv)
{
	const char *dev = (argc > 1) ? argv[1] : "/dev/mali0";
	int fd, rc, err;

	printf("mali_smoke: device %s\n", dev);

	errno = 0;
	fd = open(dev, O_RDWR);
	err = errno;
	printf("  [%s] %-30s fd=%d errno=%d (%s)\n",
	       fd >= 0 ? "PASS" : "FAIL", "open(O_RDWR)", fd, err, strerror(err));
	if (fd < 0)
		return 2;

	struct kbase_ioctl_version_check v = {
		KBASE_UK_VERSION_MAJOR, KBASE_UK_VERSION_MINOR
	};
	errno = 0;
	rc = ioctl(fd, KBASE_IOCTL_VERSION_CHECK, &v);
	err = errno;
	report("KBASE_IOCTL_VERSION_CHECK", 1, rc == 0, rc, err);
	printf("        kernel UK version = %u.%u (sent %u.%u)\n",
	       v.major, v.minor, KBASE_UK_VERSION_MAJOR, KBASE_UK_VERSION_MINOR);

	struct kbase_ioctl_get_gpuprops gp = { 0, 0, 0 };
	errno = 0;
	rc = ioctl(fd, KBASE_IOCTL_GET_GPUPROPS, &gp);
	err = errno;
	report("KBASE_IOCTL_GET_GPUPROPS", 0, rc >= 0, rc, err);
	if (rc > 0)
		printf("        GPU properties available: %d bytes\n", rc);

	struct kbase_ioctl_set_flags f = { 0 };
	errno = 0;
	rc = ioctl(fd, KBASE_IOCTL_SET_FLAGS, &f);
	err = errno;
	report("KBASE_IOCTL_SET_FLAGS", 0, rc == 0, rc, err);

	close(fd);
	printf("mali_smoke: %s\n", required_failures ? "FAIL" : "PASS");
	return required_failures ? 1 : 0;
}
