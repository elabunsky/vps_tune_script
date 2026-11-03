#!/usr/bin/env python3
"""Laptop launcher. Restore only after the operator confirms the target."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile
import time

os.umask(0o077)
parser = argparse.ArgumentParser()
parser.add_argument('host', choices=['moscow', 'fn'])
args = parser.parse_args()
here = Path(__file__).resolve().parent
bundle = here / args.host
archive = bundle / 'backup.tar.gz'
if not archive.exists():
    raise SystemExit('Archive missing: ' + str(archive))
assert json.loads((bundle / 'verification.json').read_text())['verified'], 'Backup was not verified'
print('Восстановление настроек, сайтов, генераторов и приложений:', args.host)
print('Архив:', archive)
print('Требуется Ubuntu 24.04 с той же архитектурой. Сайты и приложения будут заменены копией.')
print('При смене IP понадобится поправить адреса в Nginx, VPN и DNS. Сеть и SSH сохраняются.')
target = input('SSH-адрес сервера [' + args.host + ']: ').strip() or args.host
if target.startswith('-') or any(c.isspace() for c in target):
    raise SystemExit('Некорректный SSH-адрес')
if input('Для запуска введите RESTORE ' + args.host + ': ').strip() != 'RESTORE ' + args.host:
    raise SystemExit('Отменено')

expected = (bundle / 'SHA256SUMS').read_text().split()[0]
digest = hashlib.sha256()
with archive.open('rb') as f:
    for chunk in iter(lambda: f.read(8 * 1024 * 1024), b''):
        digest.update(chunk)
assert digest.hexdigest() == expected, 'Archive checksum differs'
ssh = ['ssh', '-T', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=20', target]
stage = '/run/web-restore-' + str(int(time.time()))
with tempfile.TemporaryDirectory(prefix='web-restore-') as tmp:
    tmp = Path(tmp)
    custom = []
    # Export only small recovery metadata, not the whole backup, to temporary storage.
    with tarfile.open(archive, 'r|gz') as t:
        for member in t:
            if member.isfile() and member.name.startswith('__webarchive__/'):
                relative = Path(member.name)
                assert not relative.is_absolute() and '..' not in relative.parts
                p = tmp / relative
                p.parent.mkdir(parents=True, exist_ok=True)
                with p.open('wb') as dst:
                    source = t.extractfile(member)
                    while chunk := source.read(1024 * 1024):
                        dst.write(chunk)
            elif member.isfile() and member.name in ('etc/passwd', 'etc/group'):
                dest = tmp / '__webarchive__' / ('saved-passwd' if member.name.endswith('passwd') else 'saved-group')
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(t.extractfile(member).read())
            if member.isfile() and member.name.startswith('etc/systemd/system/') and member.name.endswith(('.service', '.timer')) and member.name.count('/') == 3:
                custom.append(Path(member.name).name)
    meta = tmp / '__webarchive__'
    (meta / 'custom-services.json').write_text(json.dumps(custom))
    package = tmp / 'metadata.tar.gz'
    with tarfile.open(package, 'w:gz') as t:
        t.add(meta, arcname='__webarchive__')
        t.add(here / 'restore_remote.py', arcname='restore_remote.py')
    subprocess.run(ssh + ['umask 077; mkdir -p ' + shlex.quote(stage)], check=True)
    with package.open('rb') as f:
        subprocess.run(ssh + ['tar -xzf - -C ' + shlex.quote(stage)], stdin=f, check=True)

    install = input('Установить отсутствующие системные пакеты при необходимости? [Y/n]: ').strip().lower() != 'n'
    prepare = 'python3 ' + shlex.quote(stage + '/restore_remote.py') + ' prepare ' + shlex.quote(stage)
    if install:
        prepare += ' --packages'
    subprocess.run(ssh + [prepare], check=True)

    preserve = ['__webarchive__', 'etc/ssh', 'root/.ssh', 'etc/netplan', 'etc/network',
                'etc/NetworkManager', 'etc/systemd/network', 'etc/resolv.conf',
                'etc/hostname', 'etc/hosts', 'etc/machine-id', 'etc/fstab', 'etc/crypttab',
                'etc/passwd', 'etc/passwd-', 'etc/shadow', 'etc/shadow-',
                'etc/group', 'etc/group-', 'etc/gshadow', 'etc/gshadow-',
                'etc/subuid', 'etc/subgid', 'etc/ufw', 'etc/iptables', 'etc/nftables.conf',
                'var/lib/tailscale', 'var/lib/cloudflare-warp', 'var/lib/dhcp',
                'var/lib/NetworkManager', 'var/lib/apt', 'var/lib/dpkg', 'var/lib/systemd',
                'var/lib/dbus', 'var/lib/cloud', 'etc/systemd/system/tailscaled.service',
                'etc/systemd/system/warp-svc.service']
    extract = ['tar', '--extract', '--gzip', '--file=-', '--numeric-owner',
               '--same-owner', '--acls', '--xattrs', '--overwrite', '-C', '/']
    extract += ['--exclude=' + p for p in preserve]
    print('Передаю и восстанавливаю файлы. Не закрывайте окно.')
    with archive.open('rb') as f:
        subprocess.run(ssh + [shlex.join(extract)], stdin=f, check=True)
    finish = 'python3 ' + shlex.quote(stage + '/restore_remote.py') + ' finish ' + shlex.quote(stage)
    subprocess.run(ssh + [finish], check=True)
print('Восстановление завершено. Проверьте сайты, подписки и VPN.')
