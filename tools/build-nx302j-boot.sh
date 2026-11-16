#!/bin/sh
# Build the NX302J Linux boot image for slot a from the phone's own kernel and mu300's initramfs.
# Inputs are the user's own dumps; nothing device-specific is embedded here.
#
#   STOCK=backup/images/boot_a.bin MISC=backup/images/misc.bin \
#   MODULES=out/nx302j-modules BUSYBOX=out/busybox LOGDW=out/logdw \
#   sh tools/build-nx302j-boot.sh
#
# MODULES must hold the phone's first-stage .ko files (ufs-sprd-qogirn6pro, sdhci-sprd, ums9620-clk,
# ump9620-regulator, pinctrl, gpio, i2c, spi, sc27xx_adc, sprd_pmic_syscon, rpmb, dwc3-sprd*).
# They are signed by ZTE and match the stock kernel; mu300's own modules are not (MODULE_SIG_FORCE=y).
set -eu
TOP=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$TOP/.." && pwd)
STOCK=${STOCK:-$ROOT/backup/images/boot_a.bin}
MISC=${MISC:-$ROOT/backup/images/misc.bin}
MODULES=${MODULES:-$TOP/out/nx302j-modules}
BUSYBOX=${BUSYBOX:-$TOP/out/busybox}
LOGDW=${LOGDW:-$TOP/out/logdw}
UEVENTD=${UEVENTD:-$TOP/android-vendor/ueventd-perms.sh}
OUT=${OUT:-$TOP/out/boot-nx302j-a.img}
ORDER=${ORDER:-$TOP/boot/module-order-nx302j.txt}
KERNEL=${KERNEL:-$TOP/out/nx302j-kernel}

for f in "$STOCK" "$MISC" "$BUSYBOX" "$LOGDW" "$UEVENTD" "$ORDER"; do
    [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done
[ -d "$MODULES" ] || { echo "missing module directory $MODULES" >&2; exit 1; }

# the stock kernel sits at offset 4096 in the Android boot image (header v4)
PYTHON=${PYTHON:-python3}
$PYTHON - "$STOCK" "$KERNEL" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
if b[:8] != b'ANDROID!' or struct.unpack_from('<I', b, 40)[0] != 4:
    raise SystemExit('stock boot is not ANDROID! v4')
ks = struct.unpack_from('<I', b, 8)[0]
open(sys.argv[2], 'wb').write(b[4096:4096 + ks])
print('kernel', ks, 'bytes')
PY

$PYTHON "$TOP/boot/build-boot-image.py" \
    --stock-boot "$STOCK" --misc-head "$MISC" --kernel "$KERNEL" \
    --modules "$MODULES" --module-order "$ORDER" \
    --device nx302j --boot-watchdog 90 --trial-guard 90 \
    --busybox "$BUSYBOX" --logdw "$LOGDW" --ueventd-perms "$UEVENTD" \
    --out "$OUT"

# The image is always the whole partition (64 MiB); what has to stay clear of the persistent log
# area at 48 MiB is the DATA it carries, i.e. where the appended vbmeta of the stock image ends.
# Checking wc -c of the file compared the partition size and failed on every good build.
$PYTHON - "$OUT" <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb').read()
limit = 48 * 1024 * 1024
off, size = struct.unpack_from('>QQ', data, len(data) - 44)
end = off + size
print('%s: data ends at %d bytes (limit %d)' % (sys.argv[1], end, limit))
if end > limit:
    sys.exit('image data overlaps the persistent log area at 48 MiB')
PY
