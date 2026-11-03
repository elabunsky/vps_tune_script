#!/usr/bin/env bash
# Show Moscow panel credentials over SSH, or locally on the server as root.
set -euo pipefail
if [[ ! -f /etc/x-ui/x-ui.db ]]; then
    exec ssh moscow /usr/local/bin/panel-access.sh
fi
if [[ $EUID -ne 0 ]]; then
    echo 'Запустите: sudo panel-access.sh' >&2
    exit 1
fi
exec python3 - <<'PY'
import sqlite3
import subprocess
from pathlib import Path

db = sqlite3.connect('file:/etc/x-ui/x-ui.db?mode=ro', uri=True)
settings = dict(db.execute('SELECT key, value FROM settings'))
username = db.execute('SELECT username FROM users ORDER BY id LIMIT 1').fetchone()[0]
base = '/' + settings.get('webBasePath', '').strip('/') + '/'
print('Панель 3x-ui — Moscow')
print('Адрес: https://212.57.118.202:2053' + base)
print('Пользователь: ' + username)
password = None
for line in Path('/root/vpn-access/panel-access.txt').read_text().splitlines():
    key, sep, value = line.partition(':')
    if sep and key.strip().lower() in ('пароль', 'password'):
        password = value.strip()
        break
if password:
    print('Пароль: ' + password)
else:
    raise SystemExit('Сохранённый пароль не найден в /root/vpn-access/panel-access.txt')
print('Сертификат: Let’s Encrypt; автоматическое продление')
subprocess.run(['openssl', 'x509', '-in',
                '/etc/letsencrypt/live/moscow-ip/fullchain.pem',
                '-noout', '-enddate'], check=True)
print('\nVPN-подключение:')
print(Path('/root/vpn-access/client.txt').read_text().strip())
print('\nЕсли измените пароль в панели, обновите /root/vpn-access/panel-access.txt.')
PY
