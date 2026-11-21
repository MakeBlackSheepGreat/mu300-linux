#!/bin/bash
# 用宿主机原生 apk-tools 3.x 把 OpenWrt 包装满一个 aarch64 rootfs，完全绕开 qemu。
#
# 为什么需要这个脚本：qemu-user 模拟的 aarch64 apk 在每一个 I/O 路径上都不可靠 ——
# apk update 时好时坏（wget exited with error 5 / unexpected end of file），
# apk fetch 报 Bad file descriptor，apk add --root 路径解析失效，
# apk policy 连查几个包就 Segmentation fault。
# 但索引与包本身是架构无关的数据，宿主机 x86_64 的原生 apk-tools 3.0.10 能正确解析它们。
#
# 三个关键点（缺一不可）：
#   1. --arch aarch64_generic  —— 否则 apk 用宿主机 x86_64 匹配，全部 uninstallable
#   2. --usermode              —— 目标目录不属于 root 时必需
#   3. .apk 必须与 .adb 索引同目录 —— apk 按 "索引所在目录" 找包体
set -uo pipefail

REPO=${REPO:-$HOME/mu300-linux/work/apk-cache/repo}
OUT=${1:?usage: install-packages.sh <target-root> [extra-pkg...]}
shift || true
APK=$HOME/apk3/sbin/apk.static
ARCH=aarch64_generic
BASE=https://downloads.openwrt.org/releases/25.12.5
TARGETPKG=$BASE/targets/armsr/armv8/packages

mkdir -p "$REPO" "$OUT/etc/apk"
echo "$ARCH" > "$OUT/etc/apk/arch"

# build-rootfs.sh L189-194 的完整包清单
PKGS="dnsmasq-full iwinfo wireless-regdb iw-full bash ip-full coreutils-stty openssl-util curl ca-bundle msmtp luci-base \
luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn \
rpcd-mod-ucode ucode ucode-mod-fs ucode-mod-ubus ucode-mod-uci ucode-mod-uloop ucode-mod-nl80211 ucode-mod-rtnl ucode-mod-socket \
i2c-tools gpiod-tools flock ttyd luci-app-ttyd luci-i18n-ttyd-zh-cn luci-i18n-ttyd-tr python3 python3-openssl \
r8152-firmware bluez-daemon bluez-utils bluez-utils-extra dbus python3-cryptography python3-zeroconf patch $*"

echo "=== 1) 让 apk 解析完整闭包（dry-run，不安装）==="
for f in base luci packages routing telephony video kmods target; do echo "$REPO/$f.adb"; done > "$OUT/etc/apk/repositories"
"$APK" --root "$OUT" --usermode --arch "$ARCH" --allow-untrusted --no-progress \
       --no-scripts --initdb add --simulate $PKGS 2>&1 \
  | grep -oE '\([0-9]+/[0-9]+\) Installing [^ ]+ \([^)]+\)' \
  | sed -E 's/.*Installing ([^ ]+) \(([0-9][^)]*)\)/\1-\2/' \
  | sort -u > /tmp/closure.txt
echo "  闭包包数: $(wc -l < /tmp/closure.txt)"

echo "=== 2) 下载缺失的 .apk 到索引同目录 ==="
SUBS="base luci packages routing telephony video"
miss=0; got=0
while read -r pkg; do
  [ -n "$pkg" ] || continue
  if [ -s "$REPO/$pkg.apk" ]; then got=$((got+1)); continue; fi
  ok=0
  for s in $SUBS; do
    if curl -fsSL -o "$REPO/$pkg.apk.tmp" "$BASE/packages/$ARCH/$s/$pkg.apk" 2>/dev/null; then
      mv "$REPO/$pkg.apk.tmp" "$REPO/$pkg.apk"; ok=1; got=$((got+1)); break
    fi
  done
  if [ $ok -eq 0 ]; then
    if curl -fsSL -o "$REPO/$pkg.apk.tmp" "$TARGETPKG/$pkg.apk" 2>/dev/null; then
      mv "$REPO/$pkg.apk.tmp" "$REPO/$pkg.apk"; got=$((got+1))
    else
      rm -f "$REPO/$pkg.apk.tmp"; miss=$((miss+1)); echo "  MISS $pkg"
    fi
  fi
done < /tmp/closure.txt
echo "  已有/已下载: $got  缺失: $miss"
[ "$miss" -eq 0 ] || { echo "有包缺失，停止" >&2; exit 1; }

echo "=== 3) 正式安装 ==="
"$APK" --root "$OUT" --usermode --arch "$ARCH" --allow-untrusted --no-progress \
       --no-scripts add $PKGS 2>&1 | tail -8
rc=$?
echo "=== 4) 结果 ==="
echo "  apk 数据库: $(ls "$OUT/lib/apk/db/" 2>/dev/null | tr '\n' ' ')"
echo "  已装包数: $(grep -c '^P:' "$OUT/lib/apk/db/installed" 2>/dev/null || echo 0)"
exit $rc
