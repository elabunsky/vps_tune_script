#!/usr/bin/env python3
"""Single-node Moscow subscriptions; all configuration is public client data."""
import base64
import json
import secrets
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlencode, quote, urlsplit

BASE = Path(__file__).resolve().parent
SERVER = json.loads((BASE / 'server-public.json').read_text())
ROUTING = (BASE / 'routing-base64.txt').read_text().strip()

def subscription(client):
    low = 100 + secrets.randbelow(851)
    high = low + 50 + secrets.randbelow(1001 - low - 50)
    padding = f'{low}-{high}'
    q = dict(encryption='none', security='reality', type='xhttp', fp='firefox',
             sni=SERVER['sni'], pbk=SERVER['pbk'], sid=SERVER['sid'],
             host=SERVER['host'], path=SERVER['path'], mode='auto',
             x_padding_bytes=padding,
             extra=json.dumps({'mode': 'auto', 'xPaddingBytes': padding}, separators=(',', ':')))
    link = 'vless://{}@{}:{}?{}#{}'.format(uuid.uuid4(), SERVER['address'],
            SERVER['port'], urlencode(q, quote_via=quote), quote('🌍 Moscow'))
    title = base64.b64encode('BLACK TUNNEL · Moscow'.encode()).decode()
    return '\n'.join(['#profile-title: base64:' + title,
                      '#profile-update-interval: 12', '', link, '',
                      client + '://routing/onadd/' + ROUTING, ''])

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.respond(False)

    def do_HEAD(self):
        self.respond(True)

    def respond(self, head):
        path = urlsplit(self.path).path
        if path not in ('/happ.txt', '/incy.txt', '/config.txt'):
            self.send_error(404)
            return
        client = 'incy' if path in ('/incy.txt', '/config.txt') else 'happ'
        body = subscription(client).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        self.end_headers()
        if not head:
            self.wfile.write(body)

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 9075), Handler).serve_forever()
