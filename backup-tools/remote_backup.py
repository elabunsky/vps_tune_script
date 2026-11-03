#!/usr/bin/env python3
"""Stream application files plus consistent database exports over SSH."""
import datetime
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile

os.umask(0o077)
stage = Path(tempfile.mkdtemp(prefix='web-archive-', dir='/run'))
meta = stage / '__webarchive__'
meta.mkdir()

def capture(name, command, required=True):
    if not shutil.which(command[0]):
        if required:
            raise RuntimeError('Missing command: ' + command[0])
        (meta / name).write_text('Command unavailable: ' + command[0] + '\n')
        return 127
    with (meta / name).open('wb') as f:
        r = subprocess.run(command, stdout=f, stderr=subprocess.PIPE)
    if required and r.returncode:
        raise RuntimeError(name + ': ' + r.stderr.decode(errors='replace')[:300])
    return r.returncode

roots = ['etc', 'var/www', 'opt', 'usr/local', 'root', 'home', 'srv',
         'var/lib', 'var/spool', 'usr/share/nginx', 'usr/lib/nginx',
         'usr/bin/x-ui', 'usr/bin/xray', 'usr/bin/mtg']
roots = [n for n in roots if Path('/' + n).exists() or Path('/' + n).is_symlink()]
excluded = ['var/lib/apt/lists', 'var/lib/dpkg', 'var/lib/mysql',
            'var/lib/systemd', 'var/lib/cloud', 'var/lib/dbus',
            'root/.cache', 'root/.npm/_cacache', 'home/*/.cache']

try:
    capture('os-release', ['cat', '/etc/os-release'])
    capture('architecture.txt', ['dpkg', '--print-architecture'])
    capture('packages.tsv', ['dpkg-query', '-W', '-f=${binary:Package}\t${Version}\t${db:Status-Status}\n'])
    capture('manual-packages.txt', ['apt-mark', 'showmanual'])
    capture('enabled-units.txt', ['systemctl', 'list-unit-files', '--state=enabled', '--no-legend', '--no-pager'])
    capture('running-services.txt', ['systemctl', 'list-units', '--type=service', '--state=running', '--no-legend', '--no-pager', '--plain'])
    capture('timers.txt', ['systemctl', 'list-timers', '--all', '--no-pager'])
    capture('listeners.txt', ['ss', '-lntup'])
    capture('addresses.txt', ['ip', '-j', 'address'])
    capture('routes.txt', ['ip', '-j', 'route', 'show', 'table', 'all'])
    capture('nginx-expanded.conf', ['nginx', '-T'])
    capture('iptables.v4', ['iptables-save'], False)
    capture('iptables.v6', ['ip6tables-save'], False)
    capture('nftables.txt', ['nft', 'list', 'ruleset'], False)
    capture('crontab-root.txt', ['crontab', '-l'], False)
    capture('filesystems.txt', ['findmnt', '--json'])
    shutil.copyfile('/etc/passwd', meta / 'saved-passwd')
    shutil.copyfile('/etc/group', meta / 'saved-group')
    custom = [p.name for p in Path('/etc/systemd/system').glob('*.service')
              if p.is_file() and not p.is_symlink()]
    (meta / 'custom-services.json').write_text(json.dumps(custom))
    if shutil.which('docker'):
        capture('docker-containers.json', ['docker', 'ps', '-a', '--no-trunc', '--format', '{{json .}}'], False)
        capture('docker-images.json', ['docker', 'images', '--no-trunc', '--format', '{{json .}}'], False)

    snapshots = []
    errors = []
    scan_roots = ['/etc', '/opt', '/var/www', '/usr/local', '/home', '/var/lib/cdnsync', '/root']
    for root in scan_roots:
        if not Path(root).exists():
            continue
        for folder, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in ('.cache', 'node_modules', '.git', 'venv', '.venv', 'backups', 'vpn-backups', 'vpn-setup-backup')]
            for name in files:
                p = Path(folder) / name
                if not p.is_file() or p.is_symlink() or p.suffix in ('.log', '.gz', '.png', '.dat', '.zip', '.pyc'):
                    continue
                try:
                    with p.open('rb') as f:
                        is_sqlite = f.read(16) == b'SQLite format 3\x00'
                    if not is_sqlite:
                        continue
                    relative = str(p).lstrip('/')
                    dst = meta / 'sqlite' / relative
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    source = sqlite3.connect(p.as_uri() + '?mode=ro', uri=True, timeout=30)
                    target = sqlite3.connect(dst)
                    source.backup(target)
                    result = target.execute('PRAGMA integrity_check').fetchall()
                    target.close()
                    source.close()
                    if result != [('ok',)]:
                        raise RuntimeError('SQLite integrity check failed: ' + relative)
                    snapshots.append(relative)
                except (OSError, sqlite3.Error) as e:
                    errors.append({'path': str(p), 'error': str(e)})
    if errors:
        raise RuntimeError('Cannot snapshot databases: ' + json.dumps(errors))
    (meta / 'sqlite-files.json').write_text(json.dumps(snapshots, indent=2))

    mysql = subprocess.run(['systemctl', 'is-active', '--quiet', 'mysql']).returncode == 0
    if mysql:
        capture('mysql-all.sql', ['mysqldump', '--all-databases', '--single-transaction',
                '--routines', '--events', '--triggers', '--hex-blob', '--no-tablespaces'])

    manifest = {'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'hostname': os.uname().nodename, 'roots': roots, 'excluded': excluded,
                'sqlite_snapshots': snapshots, 'mysql_dump': mysql,
                'kind': 'application-and-configuration-backup',
                'live_backup': True, 'not_a_bootable_disk_image': True}
    (meta / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    print('Prepared metadata; consistent SQLite copies: ' + str(len(snapshots)), file=sys.stderr, flush=True)
    command = ['tar', '--create', '-I', 'gzip -1', '--file=-', '--numeric-owner', '--acls', '--xattrs',
               '--warning=no-file-changed', '--warning=no-file-removed', '--exclude=*.sock']
    command += ['--exclude=' + x for x in excluded]
    command += ['-C', '/'] + roots + ['-C', str(stage), '__webarchive__']
    result = subprocess.run(command)
    if result.returncode not in (0, 1):
        raise RuntimeError('tar failed: ' + str(result.returncode))
    print('Archive stream complete; tar exit=' + str(result.returncode), file=sys.stderr)
finally:
    shutil.rmtree(stage)
