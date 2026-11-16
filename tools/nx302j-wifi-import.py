#!/usr/bin/env python3
"""Write /etc/mu300/wifi-client.conf from Android WifiConfigStore.xml (SSID/PSK)."""
import argparse
from pathlib import Path
from xml.etree import ElementTree


def field(cfg, name):
    for e in cfg.iter('string'):
        if e.get('name') == name:
            return e.text
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('xml', type=Path)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--index', type=int, default=0)
    a = ap.parse_args()
    root = ElementTree.parse(a.xml).getroot()
    networks = root.findall('.//Network')
    if not networks:
        raise SystemExit('no saved network in ' + str(a.xml))
    if not 0 <= a.index < len(networks):
        raise SystemExit('network index out of range')
    cfg = networks[a.index]
    ssid = (field(cfg, 'SSID') or '').strip('"')
    psk = (field(cfg, 'PreSharedKey') or '').strip('"')
    if not ssid:
        raise SystemExit('network has no SSID')
    lines = ['SSID=' + ssid]
    if psk:
        lines.append('PSK=' + psk)
    lines += ['ENABLE=1', 'METRIC=50']
    a.out.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('wrote', a.out, 'SSID=' + ssid, 'PSK=' + ('set' if psk else 'open'))


if __name__ == '__main__':
    main()
