#!/usr/bin/env python3
"""Pack the proprietary files pulled from the user's own device into an overlay tarball for a prebuilt root filesystem.

The published images contain no vendor files; install.sh builds this overlay on the host and android-install.sh
unpacks it over the system. The layout matches rootfs/assemble.sh and openwrt/build-rootfs.sh:
  firmware/            -> usr/lib/firmware (Ubuntu) or lib/firmware (OpenWrt)
  android-subset/      -> opt/mu300/android (dev/__properties__ becomes dev-properties)
  android-gpu-subset/  -> opt/mu300/android (files already taken from android-subset win)

A subset pulled on Windows holds a file called windows-source.tar.gz (android-vendor/extract_subset.py): the
property area is a set of files named u:object_r:<context>:s0, which that file system cannot store, so the whole
device archive is kept there instead. When it is present the subset is taken from it, not from the tree, so the
installed system gets the same names and modes a Linux host would have extracted.
"""
import argparse
import copy
import io
import os
import tarfile
from pathlib import Path

# written by android-vendor/extract_subset.py on a host whose file system cannot hold every name from the device
WINDOWS_TAR = 'windows-source.tar.gz'


def add_bytes(tar, arc, data, seen, mode=0o644):
    if arc in seen:
        return
    seen.add(arc)
    info = tarfile.TarInfo(arc)
    info.size, info.mode, info.uid, info.gid, info.uname, info.gname = len(data), mode, 0, 0, 'root', 'root'
    tar.addfile(info, io.BytesIO(data))


def add_dir(tar, arc, seen, keep):
    """directory entries for arc, but none for its first `keep` components: those exist in the system already, and
    an entry for one of them could replace it - Ubuntu's lib is a link to usr/lib"""
    parts = arc.split('/')
    for i in range(keep + 1, len(parts) + 1):
        d = '/'.join(parts[:i])
        if d in seen:
            continue
        seen.add(d)
        info = tarfile.TarInfo(d)
        info.type, info.mode, info.uid, info.gid, info.uname, info.gname = tarfile.DIRTYPE, 0o755, 0, 0, 'root', 'root'
        tar.addfile(info)


def add_kernel_bundle(tar, bundle: Path, os_name, seen):
    """the modules of another kernel (an unpacked mu300-kernel-6.18.tar.gz), laid out as mu300-update installs
    them: Ubuntu under lib/modules/<release>/extra (depmod on the device indexes them), OpenWrt flat (it loads
    them by path)"""
    krel = (bundle / 'kernel.release').read_text().strip()
    kos = sorted((bundle / 'modules').glob('*.ko'))
    # the real path: in Ubuntu lib is a link to usr/lib, in OpenWrt a directory
    parent = 'usr/lib/modules' if os_name == 'ubuntu' else 'lib/modules'
    base = f'{parent}/{krel}'
    sub = f'{base}/extra' if os_name == 'ubuntu' else base
    add_dir(tar, sub, seen, keep=len(parent.split('/')))
    for ko in kos:
        add_bytes(tar, f'{sub}/{ko.name}', ko.read_bytes(), seen)
    if os_name == 'ubuntu':
        for f in ('modules.builtin', 'modules.builtin.modinfo'):
            if (bundle / f).is_file():
                add_bytes(tar, f'{base}/{f}', (bundle / f).read_bytes(), seen)
        # the index (modules.dep): wifi-start runs depmod early in every boot
        add_bytes(tar, f'{base}/modules.order', b'', seen)
    return krel, len(kos)


def host_free_mode(arc, is_dir):
    """PR #199: derive imported modes from purpose, not FAT/exFAT host modes."""
    if is_dir:
        return 0o755
    parts = arc.split('/')
    if 'dev-properties' in parts[:-1]:
        return 0o444
    # Every directory whose files are run rather than read, matched by name so
    # this keeps working when a new such directory appears:
    #   bin / busybox-bin - the helpers, including the mountpoint shim
    #   init.d            - procd services; at 0644 procd refuses them with
    #                       exit_code 127, and android-install.sh then also skips
    #                       the rc.d symlink because it requires them executable
    #   uci-defaults      - they run once at first boot
    #   netifd/proto      - netifd protocol handlers; at 0666 it silently reports
    #                       "proto": "none" and never calls back into the script
    # busybox-bin was added after a real failure: its mountpoint shim arrived as
    # 0666 and android-vendor-start aborted with "mountpoint: Permission denied",
    # so the Android chroot never mounted and the modem was never released.
    # netifd/proto was added after the same class of failure: mu300cell.sh arrived
    # as 0666, so `ubus call network.interface.wan status` answered
    # {"available": false, "proto": "none"} and the cellular WAN was never set up
    # even though /etc/config/network named proto 'mu300cell'.
    #
    # The parent directory has to be read with parts[-2], not parts[-2:-1]: the slice
    # yields a one-element list, and "['bin'] in ('bin', 'busybox-bin')" is always
    # False, so the bin/busybox-bin rule never fired and every helper in
    # opt/mu300/bin arrived as 0644.
    parent = parts[-2] if len(parts) >= 2 else ''
    if parent in ('bin', 'busybox-bin') or 'init.d' in parts[:-1] \
            or 'uci-defaults' in parts[:-1] \
            or (parent == 'proto' and 'netifd' in parts[:-1]):
        return 0o755
    return 0o644


def add_tree(tar, src: Path, dest: str, seen: set, rename=None):
    for root, dirs, files in os.walk(src, followlinks=False):
        dirs.sort()
        rel_root = Path(root).relative_to(src)
        entries = [(d, True) for d in dirs] + [(f, False) for f in sorted(files)]
        # symlinks to directories show up in dirs but must be stored as links
        for name, _ in entries:
            if name == WINDOWS_TAR and rel_root == Path('.'):
                continue
            path = Path(root) / name
            rel = (rel_root / name).as_posix()
            if rename:
                rel = rename(rel)
                if rel is None:
                    continue
            arc = f'{dest}/{rel}'
            if arc in seen:
                continue
            seen.add(arc)
            info = tar.gettarinfo(str(path), arcname=arc)
            info.mode = 0o777 if info.issym() else host_free_mode(arc, info.isdir())
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            if info.isfile():
                with open(path, 'rb') as f:
                    tar.addfile(info, f)
            else:
                tar.addfile(info)
        dirs[:] = [d for d in dirs if not (Path(root) / d).is_symlink()]


def add_members(tar, src: Path, dest: str, seen: set, rename=None):
    """the same, for a subset whose tree is not complete on this host: everything comes out of
    src/windows-source.tar.gz, with the names, modes and links the file system could not keep"""
    side = src / WINDOWS_TAR
    if not side.is_file():
        return 0
    n = 0
    with tarfile.open(side, 'r:*') as stored:
        for m in stored.getmembers():
            rel = m.name.lstrip('./')
            if rename:
                rel = rename(rel)
                if rel is None:
                    continue
            arc = f'{dest}/{rel}'
            if arc in seen:
                continue
            seen.add(arc)
            info = copy.copy(m)
            info.name = arc
            info.mode = 0o777 if info.issym() else host_free_mode(arc, info.isdir())
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            tar.addfile(info, stored.extractfile(m) if m.isreg() else None)
            n += 1
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--os', required=True, choices=['ubuntu', 'openwrt'])
    ap.add_argument('--firmware', type=Path)
    ap.add_argument('--android-subset', type=Path, required=True)
    ap.add_argument('--gpu-subset', type=Path)
    ap.add_argument('--kernel-bundle', type=Path,
                    help='unpacked mu300-kernel-6.18.tar.gz: its modules go into the system too')
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()

    def android(rel):
        # the property area snapshot moves out of dev/ (a devtmpfs is mounted there on the device)
        if rel == 'dev/__properties__' or rel.startswith('dev/__properties__/'):
            return 'dev-properties' + rel[len('dev/__properties__'):]
        if rel == 'dev' or rel.startswith('dev/'):
            return None
        return rel

    def gpu(rel):
        return None if rel == 'dev' or rel.startswith('dev/') else rel

    seen = set()
    with tarfile.open(a.out, 'w:gz', format=tarfile.GNU_FORMAT) as tar:
        if a.firmware and a.firmware.is_dir():
            add_tree(tar, a.firmware, 'usr/lib/firmware' if a.os == 'ubuntu' else 'lib/firmware', seen)
        # a subset built on Windows keeps the device data in windows-source.tar.gz: its tree is missing
        # every name that file system cannot store (the property area) and every file mode, so take the
        # whole subset from the archive instead of walking it
        if (a.android_subset / WINDOWS_TAR).is_file():
            add_members(tar, a.android_subset, 'opt/mu300/android', seen, android)
        else:
            add_tree(tar, a.android_subset, 'opt/mu300/android', seen, android)
        if a.gpu_subset and a.gpu_subset.is_dir():
            add_tree(tar, a.gpu_subset, 'opt/mu300/android', seen, gpu)
        if a.kernel_bundle:
            krel, n = add_kernel_bundle(tar, a.kernel_bundle, a.os, seen)
            print(f'{a.out}: {n} modules for {krel}')
    print(f'{a.out}: {len(seen)} entries')


if __name__ == '__main__':
    main()
