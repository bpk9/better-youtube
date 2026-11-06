#!/usr/bin/env python3
"""Generate private pairing material. Run locally, then copy server/ to your server."""
from project_config import companion_host, configure_companion_ats, configure_google, setup_ios, validate_client
import argparse
import hashlib
import ipaddress
import os
import plistlib
import secrets
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True, help='IP or DNS name the iPhone uses, including a Tailscale address')
parser.add_argument('--bind-ip', help='Numeric IP on the Docker host; required when --host is a DNS name')
parser.add_argument('--reuse-certificate', action='store_true', help='Keep the existing TLS certificate and app pin')
parser.add_argument('--google-client-id')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
try:
    args.host = companion_host(args.host)
    bind_ip = ipaddress.ip_address(args.bind_ip or args.host)
    if bind_ip.is_unspecified or bind_ip.is_multicast or '%' in str(bind_ip):
        raise ValueError('Use a specific unicast --bind-ip, not a wildcard address.')
except ValueError as error:
    parser.error(f'{error} Supply --bind-ip with a numeric address on the Docker host.')
if args.google_client_id:
    try: args.google_client_id = validate_client(args.google_client_id)
    except ValueError as error: parser.error(str(error))
server = root / 'server'
tls = server / 'tls'
if args.reuse_certificate and not all((tls / name).is_file() for name in ('cert.pem', 'key.pem')):
    parser.error('--reuse-certificate requires existing server/tls/cert.pem and key.pem')
setup_ios(root)
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
    san = 'DNS:' + args.host
if not args.reuse_certificate:
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650',
        '-keyout', str(tls / 'key.pem'), '-out', str(tls / 'cert.pem'), '-subj', '/CN=Better YouTube Companion',
        '-addext', 'subjectAltName=' + san], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
os.chmod(tls / 'key.pem', 0o600)
cert = subprocess.check_output(['openssl', 'x509', '-in', str(tls / 'cert.pem'), '-outform', 'DER'])
values.update(BETTER_TOKEN=token, BETTER_BIND_IP=str(bind_ip))
values.setdefault('BETTER_POLL_SECONDS', '1800')
values.setdefault('BETTER_CACHE_BYTES', '5368709120')
env.write_text(''.join(f'{key}={value}\n' for key, value in values.items()))
os.chmod(env, 0o600)
connection = root / 'ios/BetterYouTube/Connection.plist'
config = plistlib.loads(connection.read_bytes()) if connection.exists() else {}
url_host = '[' + args.host + ']' if ':' in args.host else args.host
config.update(ServerURL='https://' + url_host + ':8447', ServerToken=token, CertificateSHA256=hashlib.sha256(cert).hexdigest())
connection.write_bytes(plistlib.dumps(config)); os.chmod(connection, 0o600)
configure_companion_ats(root)
if args.google_client_id:
    configure_google(root, args.google_client_id)
print('Pairing configured for', args.host, '(Docker bind:', str(bind_ip) + ') — secrets were not printed.')
