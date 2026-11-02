#!/usr/bin/env python3
"""Deploy only companion files over SSH; never print pairing credentials."""
import argparse
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FILES = ('app.py', 'requirements.txt', 'Dockerfile', '.dockerignore', 'compose.yaml',
         '.env', 'tls/cert.pem', 'tls/key.pem')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ssh', required=True, help='SSH destination (user@host or configured alias)')
    parser.add_argument('--identity', type=Path, help='Optional SSH private-key path (never uploaded)')
    parser.add_argument('--directory', required=True, help='Dedicated absolute deployment directory')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.@-]+', args.ssh) or args.ssh.startswith('-'):
        parser.error('Invalid SSH destination')
    if not args.directory.startswith('/') or args.directory == '/':
        parser.error('Use a dedicated absolute directory')
    for name in FILES:
        if not (ROOT / 'server' / name).is_file():
            parser.error('Missing server/' + name + '; run prepare-companion.py first')
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10']
    if args.identity:
        ssh += ['-o', 'IdentitiesOnly=yes', '-i', str(args.identity.expanduser())]
    ssh.append(args.ssh)
    subprocess.run(ssh + ['docker compose version >/dev/null'], check=True)
    directory = shlex.quote(args.directory)
    # Only a fixed allowlist crosses SSH; no runtime database or local test media.
    with tempfile.TemporaryFile() as archive:
        with tarfile.open(fileobj=archive, mode='w') as tar:
            for name in FILES:
                tar.add(ROOT / 'server' / name, arcname=name, recursive=False)
        archive.seek(0)
        subprocess.run(ssh + [f'umask 077; mkdir -p {directory} && tar --no-same-owner -xf - -C {directory}'], stdin=archive, check=True)
    # Root on the target is required for container UID ownership, not world-readable keys.
    command = f'''set -eu
cd {directory}
chmod 700 .
chmod 600 .env
mkdir -p state
chown 10001:10001 state tls tls/key.pem tls/cert.pem
chmod 700 state tls
chmod 600 tls/key.pem
chmod 644 tls/cert.pem
docker compose -p better-youtube up -d --build --wait --wait-timeout 120
'''
    subprocess.run(ssh + [command], check=True)
    print('Companion deployed and container health check passed. Run verify-companion.py next.')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f'Deployment stopped (exit {error.returncode}). Resolve the reported SSH/Docker error and rerun.')
