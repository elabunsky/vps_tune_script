#!/usr/bin/env python3
import concurrent.futures
import datetime
import hashlib
import json
from pathlib import Path
import os
import subprocess
import tarfile

os.umask(0o077)
HERE = Path(__file__).resolve().parent
DEST = Path.home() / 'web_archive'
STAMP = os.environ.get('WEB_ARCHIVE_STAMP', datetime.datetime.now().strftime('%Y-%m-%d_%H-%M-%S'))
RUN = DEST / STAMP
RUN.mkdir(parents=True, mode=0o700, exist_ok=True)
script = (HERE / 'remote_backup.py').read_bytes()

def backup(host):
    dest = RUN / host
    dest.mkdir(mode=0o700, exist_ok=True)
    if (dest / 'backup.tar.gz').exists():
        raise FileExistsError('Refusing to overwrite completed backup: ' + str(dest))
    partial = dest / 'backup.tar.gz.partial'
    with partial.open('wb') as out, (dest / 'backup.log').open('wb') as log:
        r = subprocess.run(['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
                            '-o', 'ServerAliveInterval=20', '-o', 'ServerAliveCountMax=6',
                            host, 'python3 -'], input=script, stdout=out, stderr=log)
    if r.returncode:
        raise RuntimeError(host + ': backup failed; see ' + str(dest / 'backup.log'))
    archive = dest / 'backup.tar.gz'
    partial.rename(archive)
    sha = hashlib.sha256()
    with archive.open('rb') as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b''):
            sha.update(chunk)
    (dest / 'SHA256SUMS').write_text(sha.hexdigest() + '  backup.tar.gz\n')
    names = []
    with tarfile.open(archive, 'r|gz') as t:
        for member in t:
            names.append(member.name)
            if member.isfile():
                f = t.extractfile(member)
                if member.name == '__webarchive__/manifest.json':
                    (dest / 'manifest.json').write_bytes(f.read())
                else:
                    while f.read(1024 * 1024):
                        pass
    assert '__webarchive__/manifest.json' in names
    assert 'etc/nginx/nginx.conf' in names
    if host == 'moscow':
        for required in ['opt/cdnsync-subgen/subgen.py', 'opt/cdnsync-subgen/routing-base64.txt',
                         'etc/systemd/system/cdnsync-subgen.service',
                         'var/www/vpn-landing/happ.html', 'var/www/vpn-landing/incy.html',
                         'etc/nginx/conf.d/cdnsync-domain.conf']:
            assert required in names, required
    (dest / 'contents.txt').write_text('\n'.join(names) + '\n')
    report = {'host': host, 'archive': str(archive), 'bytes': archive.stat().st_size,
              'members': len(names), 'sha256': sha.hexdigest(), 'verified': True}
    (dest / 'verification.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report), flush=True)
    return report

if __name__ == '__main__':
    print('Backup destination: ' + str(RUN), flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(backup, ['moscow', 'fn']))
    (RUN / 'summary.json').write_text(json.dumps(results, indent=2))
    latest = DEST / 'latest'
    if latest.is_symlink():
        latest.unlink()
    latest.symlink_to(RUN.name)
    print('Both backups completed and verified.', flush=True)
