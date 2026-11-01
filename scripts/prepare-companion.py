#!/usr/bin/env python3
"""Generate private pairing material. Run locally, then copy server/ to your server."""
from project_config import configure_google, setup_ios, validate_client
import argparse
import hashlib
import ipaddress
import os
import plistlib
import secrets
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True)
parser.add_argument('--google-client-id')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
if args.google_client_id:
    try: args.google_client_id = validate_client(args.google_client_id)
    except ValueError as error: parser.error(str(error))
setup_ios(root)
server = root / 'server'
tls = server / 'tls'
tls.mkdir(exist_ok=True)
env = server / '.env'
values = {}
if env.exists():
    values = dict(line.split('=', 1) for line in env.read_text().splitlines() if '=' in line)
token = values.get('BETTER_TOKEN') or secrets.token_urlsafe(48)
try:
    ipaddress.ip_address(args.host)
    san = 'IP:' + args.host
except ValueError:
    if not all(c.isalnum() or c in '.-' for c in args.host):
        raise SystemExit('Use an IP address or hostname.')
    san = 'DNS:' + args.host
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650',
    '-keyout', str(tls / 'key.pem'), '-out', str(tls / 'cert.pem'), '-subj', '/CN=Better YouTube Companion',
    '-addext', 'subjectAltName=' + san], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
os.chmod(tls / 'key.pem', 0o600)
cert = subprocess.check_output(['openssl', 'x509', '-in', str(tls / 'cert.pem'), '-outform', 'DER'])
env.write_text('BETTER_TOKEN=' + token + '\nBETTER_BIND_IP=' + args.host + '\nBETTER_POLL_SECONDS=1800\nBETTER_CACHE_BYTES=5368709120\n')
os.chmod(env, 0o600)
connection = root / 'ios/BetterYouTube/Connection.plist'
config = plistlib.loads(connection.read_bytes()) if connection.exists() else {}
config.update(ServerURL='https://' + args.host + ':8447', ServerToken=token, CertificateSHA256=hashlib.sha256(cert).hexdigest())
connection.write_bytes(plistlib.dumps(config)); os.chmod(connection, 0o600)
if args.google_client_id:
    configure_google(root, args.google_client_id)
print('Pairing material created for', args.host, '— secrets were not printed.')
