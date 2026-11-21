#!/bin/bash
# 在宿主机上组装完整的 MU300/NX302J OpenWrt rootfs，完全绕开 qemu。
#
# 为什么不用 openwrt/build-rootfs.sh：
#   它依赖 docker --platform linux/arm64 + binfmt，即 qemu-user 模拟 aarch64。
#   在那套环境下 apk 的每一步都不可靠：apk update 时好时坏（wget exited with error 5 /
#   unexpected end of file），apk fetch 报 Bad file descriptor，apk add --root 路径解析失效，
#   apk policy 连查几个包就 Segmentation fault。构建会随机失败在任一阶段。
#
# 本脚本的做法：
#   索引与 .apk 是架构无关的数据，宿主机 x86_64 的原生 apk-tools 3.0.10 能正确解析它们，
#   把 aarch64_generic 的包直接解到目标 rootfs。三个必需参数：
#     --arch aarch64_generic  否则 apk 按宿主机 x86_64 匹配，全部 uninstallable
#     --usermode              目标目录不属于 root 时必需
#     .apk 与 .adb 必须同目录  apk 按索引所在目录找包体
#
# 用法：openwrt/build-rootfs-host.sh [OUT.tar.gz]
set -uo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$TOP/openwrt/mu300-openwrt-rootfs.tar.gz}
VER=25.12.5
ARCH=aarch64_generic
BASE=https://downloads.openwrt.org/releases/$VER
KPATH=$BASE/targets/armsr/armv8
CACHE=${MU300_APK_CACHE:-$TOP/work/apk-cache}
REPO=$CACHE/repo
APK=${MU300_APK:-$HOME/apk3/sbin/apk.static}
R=$(mktemp -d /tmp/mu300-root.XXXXXX)
trap 'echo "rootfs 保留在 $R"' EXIT

[ -x "$APK" ] || { echo "需要 apk-tools 3.x: $APK" >&2; exit 1; }
mkdir -p "$REPO"

echo "########## 1) 基底：官方 rootfs tarball ##########"
TARBALL=$TOP/openwrt/openwrt-$VER-armsr-armv8-rootfs.tar.gz
[ -s "$TARBALL" ] || curl -fL -o "$TARBALL" "$BASE/targets/armsr/armv8/openwrt-$VER-armsr-armv8-rootfs.tar.gz"
tar -xzf "$TARBALL" -C "$R"
echo "  基底包数: $(grep -c '^P:' "$R/lib/apk/db/installed")"

echo "########## 2) 索引 ##########"
for r in base luci packages routing telephony video; do
    f="$REPO/$r.adb"
    [ -s "$f" ] || curl -fsSL -o "$f.part" "$BASE/packages/$ARCH/$r/packages.adb" && mv "$f.part" "$f" 2>/dev/null
done
[ -s "$REPO/target.adb" ] || curl -fsSL -o "$REPO/target.adb" "$KPATH/packages/packages.adb"
KSUB=$(curl -fsSL "$KPATH/kmods/" | grep -oE '6\.[0-9]+\.[0-9]+-[0-9]+-[0-9a-f]+' | head -1)
[ -s "$REPO/kmods.adb" ] || curl -fsSL -o "$REPO/kmods.adb" "$KPATH/kmods/$KSUB/packages.adb"

echo "########## 3) 解析闭包 ##########"
for f in base luci packages routing telephony video target kmods; do echo "$REPO/$f.adb"; done > "$R/etc/apk/repositories"
echo "$ARCH" > "$R/etc/apk/arch"
PKGS="dnsmasq-full iwinfo wireless-regdb iw-full bash ip-full coreutils-stty openssl-util curl ca-bundle msmtp luci-base \
luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn \
rpcd-mod-ucode ucode ucode-mod-fs ucode-mod-ubus ucode-mod-uci ucode-mod-uloop ucode-mod-nl80211 ucode-mod-rtnl ucode-mod-socket \
i2c-tools gpiod-tools flock ttyd luci-app-ttyd luci-i18n-ttyd-zh-cn luci-i18n-ttyd-tr python3 python3-openssl \
r8152-firmware bluez-daemon bluez-utils bluez-utils-extra dbus python3-cryptography python3-zeroconf patch"
"$APK" --root "$R" --usermode --arch "$ARCH" --allow-untrusted --no-progress --no-scripts --initdb \
       add --simulate $PKGS 2>&1 \
  | sed -nE 's/^\( *[0-9]+\/[0-9]+\) Installing ([^ ]+) \((.*)\)$/\1-\2/p' | sort -u > /tmp/mu300-closure.txt
echo "  闭包: $(wc -l < /tmp/mu300-closure.txt)"

echo "########## 4) 下载缺失的 .apk（宿主机 curl，可靠）##########"
miss=0
while read -r pkg; do
    [ -n "$pkg" ] || continue
    [ -s "$REPO/$pkg.apk" ] && continue
    ok=0
    for s in base luci packages routing telephony video; do
        curl -fsSL -o "$REPO/$pkg.apk.tmp" "$BASE/packages/$ARCH/$s/$pkg.apk" 2>/dev/null \
          && { mv "$REPO/$pkg.apk.tmp" "$REPO/$pkg.apk"; ok=1; break; }
    done
    [ $ok -eq 1 ] && continue
    curl -fsSL -o "$REPO/$pkg.apk.tmp" "$KPATH/packages/$pkg.apk" 2>/dev/null \
      && { mv "$REPO/$pkg.apk.tmp" "$REPO/$pkg.apk"; ok=1; }
    [ $ok -eq 1 ] && continue
    curl -fsSL -o "$REPO/$pkg.apk.tmp" "$KPATH/kmods/$KSUB/$pkg.apk" 2>/dev/null \
      && { mv "$REPO/$pkg.apk.tmp" "$REPO/$pkg.apk"; ok=1; }
    [ $ok -eq 0 ] && { rm -f "$REPO/$pkg.apk.tmp"; miss=$((miss+1)); echo "  MISS $pkg"; }
done < /tmp/mu300-closure.txt
[ $miss -eq 0 ] || { echo "$miss 个包下载失败" >&2; exit 1; }

echo "########## 5) 安装 ##########"
"$APK" --root "$R" --usermode --arch "$ARCH" --allow-untrusted --no-progress --no-scripts add $PKGS 2>&1 | tail -3

echo "########## 6) 定制 APK ##########"
CUSTOM=""
for f in "$TOP"/work/wifi-sae/*.apk "$TOP"/work/iwinfo-ap-scan/*.apk; do
    [ -s "$f" ] && { cp -f "$f" "$REPO/"; CUSTOM="$CUSTOM $REPO/$(basename "$f")"; }
done
[ -s "$TOP/work/block-mount-mu300.apk" ] && { cp -f "$TOP/work/block-mount-mu300.apk" "$REPO/"; CUSTOM="$CUSTOM $REPO/block-mount-mu300.apk"; }
[ -n "$CUSTOM" ] && "$APK" --root "$R" --usermode --arch "$ARCH" --allow-untrusted \
    --no-progress --no-scripts --force-non-repository add $CUSTOM 2>&1 | tail -3

echo "########## 7) overlay ##########"
mkdir -p "$R/opt"
cp -a "$TOP/rootfs/overlay/opt/mu300/." "$R/opt/mu300/"
mkdir -p "$R/usr/share/ucode/mu300"
cp -a "$TOP/rootfs/overlay/usr/share/ucode/mu300/." "$R/usr/share/ucode/mu300/"
cp -a "$TOP/openwrt/overlay/." "$R/"
cp -a "$TOP/openwrt/luci-app-mu300/root/." "$R/"
cp -a "$TOP/openwrt/luci-app-mu300/htdocs/." "$R/www/"
[ -d "$TOP/openwrt/luci-app-unisoc-ota/root" ] && cp -a "$TOP/openwrt/luci-app-unisoc-ota/root/." "$R/"
[ -d "$TOP/openwrt/luci-app-unisoc-ota/htdocs" ] && cp -a "$TOP/openwrt/luci-app-unisoc-ota/htdocs/." "$R/www/"

echo "########## 8) Wi-Fi 补丁（两个，按顺序）##########"
patch --batch --fuzz=0 -d "$R" -p1 -i "$TOP/openwrt/patches/wifi-scripts-no-dfs.patch"
grep -q "device_no_dfs(config);" "$R/usr/share/ucode/wifi/hostapd.uc" || { echo "DFS 补丁未生效" >&2; exit 1; }
patch --batch --fuzz=0 -d "$R" -p1 -i "$TOP/openwrt/patches/wifi-scripts-chanlist-band.patch"
grep -q "device_chanlist_band(config);" "$R/usr/share/ucode/wifi/hostapd.uc" || { echo "band 补丁未生效" >&2; exit 1; }

echo "########## 9) 权限与服务 ##########"
chmod 755 "$R"/opt/mu300/bin/* 2>/dev/null
chmod 755 "$R"/etc/init.d/* 2>/dev/null
chmod 755 "$R"/etc/uci-defaults/* 2>/dev/null
find "$R/usr/libexec" -type f -exec chmod 755 {} \; 2>/dev/null
chmod 0644 "$R"/usr/share/rpcd/ucode/*.uc "$R"/usr/share/ucode/mu300/*.uc 2>/dev/null
for s in mu300-accounts mu300-cpu-driver mu300-service-cpus mu300-vendor mu300-charge-mode mu300-hw mu300-post \
         mu300-toolkit mu300-atd mu300-network-recovery mu300-modem-log mu300-wifi-client mu300-sysd mu300-ndp \
         mu300-smsd mu300-user-packages unisoc-battery ttyd mu300-hotspot mu300-sipa mu300-bt \
         unisoc-modem-ui unisoc-sms-forward unisoc-traffic dnsmasq bluetoothd; do
    [ -f "$R/etc/init.d/$s" ] || continue
    n=$(sed -n "s/^START=//p" "$R/etc/init.d/$s" | head -1)
    [ -n "$n" ] || continue
    ln -sf "../init.d/$s" "$R/etc/rc.d/S$n$s" 2>/dev/null
done

echo "########## 10) root 密码（与 u30air 一致：root/root）##########"
rm -f "$R"/etc/uhttpd.key "$R"/etc/uhttpd.crt
root_hash='$6$mu300root$O/wH3K.NhG6ZZOMSOTLlNNHv08B1RRcRsec0Xc54SuqhFhgPwmQUnxo782srY03f5mYk.Gv0qJ8JGfcrJvYKs.'
grep -q "^root:" "$R/etc/shadow" && sed -i "s|^root:[^:]*:|root:$root_hash:|" "$R/etc/shadow"

echo "########## 11) 打包 ##########"
(cd "$R" && tar -czf "$OUT" .)
echo "  包数: $(grep -c '^P:' "$R/lib/apk/db/installed")"
echo "  文件: $(find "$R" -type f | wc -l)"
ls -la "$OUT"
echo "BUILD_DONE rootfs=$R"
