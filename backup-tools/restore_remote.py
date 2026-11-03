#!/usr/bin/env python3
"""Executed over root SSH by restore.py; no automatic reboot or firewall reload."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import time

p = argparse.ArgumentParser()
p.add_argument('action', choices=['prepare', 'finish'])
p.add_argument('stage')
p.add_argument('--packages', action='store_true')
args = p.parse_args()
stage = Path(args.stage)
meta = stage / '__webarchive__'
assert os.geteuid() == 0, 'Connect as root'
assert stage.is_relative_to('/run') and meta.is_dir()

def run(cmd, check=True):
    return subprocess.run(cmd, check=check)

if args.action == 'prepare':
    os_release = Path('/etc/os-release').read_text()
    assert 'VERSION_ID="24.04"' in os_release, 'Requires Ubuntu 24.04'
    arch = subprocess.check_output(['dpkg', '--print-architecture'], text=True).strip()
    assert arch == (meta / 'architecture.txt').read_text().strip(), 'CPU architecture differs'
    # Preserve networking, SSH access and machine identity on the target machine.
    target_packages = set(subprocess.check_output(['dpkg-query', '-W', '-f=${binary:Package}\n'], text=True).splitlines())
    saved = []
    for line in (meta / 'packages.tsv').read_text().splitlines():
        name, version, state = line.split('\t')
        if state == 'installed' and not name.startswith(('linux-', 'grub-', 'shim-')):
            saved.append(name)
    missing = sorted(set(saved) - target_packages)
    (stage / 'missing-packages.txt').write_text('\n'.join(missing))
    if missing:
        if not args.packages:
            raise RuntimeError('Missing packages; rerun with automatic package installation enabled')
        run(['apt-get', 'update'])
        run(['apt-get', 'install', '-y', '--no-install-recommends'] + missing)
    # Refuse account-ID conflicts; merge only missing application accounts.
    import pwd, grp
    for line in (meta / 'saved-group').read_text().splitlines():
        name, _, gid, members = line.split(':')
        if name in {g.gr_name for g in grp.getgrall()}:
            assert grp.getgrnam(name).gr_gid == int(gid), 'Group ID differs: ' + name
        else:
            assert int(gid) not in {g.gr_gid for g in grp.getgrall()}, 'Group ID already used: ' + gid
            run(['groupadd', '-g', gid, name])
    for line in (meta / 'saved-passwd').read_text().splitlines():
        name, _, uid, gid, gecos, home, shell = line.split(':')
        if name in {u.pw_name for u in pwd.getpwall()}:
            assert pwd.getpwnam(name).pw_uid == int(uid), 'User ID differs: ' + name
        else:
            assert int(uid) not in {u.pw_uid for u in pwd.getpwall()}, 'User ID already used: ' + uid
            run(['useradd', '-M', '-u', uid, '-g', gid, '-d', home, '-s', shell, '-c', gecos, name])
    running = [line.split()[0] for line in (meta / 'running-services.txt').read_text().splitlines() if line.strip()]
    custom = set(json.loads((meta / 'custom-services.json').read_text()))
    known = {'nginx.service', 'mysql.service', 'mariadb.service', 'php8.3-fpm.service',
             'docker.service', 'containerd.service', 'lighttpd.service', 'named.service',
             'dnsmasq.service', 'fail2ban.service', 'proftpd.service'}
    selected = sorted(set(running) & (custom | known))
    enabled_timers = [line.split()[0] for line in (meta / 'enabled-units.txt').read_text().splitlines()
                      if line.strip() and line.split()[0].endswith('.timer')]
    selected += sorted(set(enabled_timers) & custom)
    protected = {'ssh.service', 'sshd.service', 'systemd-networkd.service', 'systemd-resolved.service',
                 'systemd-journald.service', 'systemd-logind.service', 'systemd-udevd.service',
                 'dbus.service', 'tailscaled.service', 'warp-svc.service'}
    selected = [u for u in selected if u not in protected]
    (stage / 'restart-services.json').write_text(json.dumps(selected))
    recovery = Path('/root/web-archive-before-restore-' + time.strftime('%Y%m%d-%H%M%S'))
    recovery.mkdir(mode=0o700)
    with tarfile.open(recovery / 'etc.tar.gz', 'w:gz') as t:
        t.add('/etc', arcname='etc')
    print('Current /etc saved:', recovery)
    for service in selected:
        run(['systemctl', 'stop', service], check=False)
    print('READY_FOR_RESTORE')
else:
    snapshots = json.loads((meta / 'sqlite-files.json').read_text())
    for relative in snapshots:
        source = meta / 'sqlite' / relative
        target = Path('/') / relative
        if not source.exists():
            raise RuntimeError('Missing SQLite snapshot: ' + relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        owner = target.stat() if target.exists() else source.stat()
        for suffix in ('-wal', '-shm', '-journal'):
            Path(str(target) + suffix).unlink(missing_ok=True)
        shutil.copyfile(source, target)
        os.chown(target, owner.st_uid, owner.st_gid)
        target.chmod(owner.st_mode & 0o777)
        c = sqlite3.connect(target.as_uri() + '?mode=ro', uri=True)
        assert c.execute('PRAGMA integrity_check').fetchall() == [('ok',)], relative
        c.close()
    run(['systemctl', 'daemon-reload'])
    # Network tuning used by VPN forwarding; unsupported kernel keys are reported.
    run(['sysctl', '--system'], check=False)
    dump = meta / 'mysql-all.sql'
    if dump.exists():
        run(['systemctl', 'start', 'mysql'])
        with dump.open('rb') as f:
            subprocess.run(['mysql'], stdin=f, check=True)
    run(['nginx', '-t'])
    binary = Path('/usr/local/x-ui/bin/xray-linux-amd64')
    config = Path('/usr/local/x-ui/bin/config.json')
    if binary.exists() and config.exists():
        run([str(binary), 'run', '-test', '-c', str(config)])
    selected = json.loads((stage / 'restart-services.json').read_text())
    failures = []
    for service in selected:
        if subprocess.run(['systemctl', 'start', service]).returncode:
            failures.append(service)
    print('Restored SQLite snapshots:', len(snapshots))
    if failures:
        raise RuntimeError('Services failed to start: ' + ', '.join(failures))
    print('RESTORE_COMPLETE. Check sites and VPN. Networking and firewall were not replaced.')
