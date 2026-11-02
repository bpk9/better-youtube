#!/usr/bin/env python3
"""Verify the paired companion without printing credentials or signed media URLs."""
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import plistlib
import ssl
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--connection', type=Path, default=ROOT / 'ios/BetterYouTube/Connection.plist')
    parser.add_argument('--video', help='Optionally prepare a real video ID and verify its MP4 bytes')
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    config = plistlib.loads(args.connection.read_bytes())
    url = urlsplit(config['ServerURL'])
    assert url.scheme == 'https'

    def request(method, path, body=None, auth=True, headers=None):
        connection = http.client.HTTPSConnection(url.hostname, url.port or 443,
            context=ssl._create_unverified_context(), timeout=30)
        try:
            connection.connect()
            # Validate the exact app pin BEFORE sending authentication material.
            actual = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest()
            if actual != config['CertificateSHA256'].lower():
                raise RuntimeError('Server certificate does not match the app pairing')
            h = dict(headers or {})
            if auth:
                h['Authorization'] = 'Bearer ' + config['ServerToken']
            if body is not None:
                h['Content-Type'] = 'application/json'
                body = json.dumps(body)
            connection.request(method, path, body, h)
            response = connection.getresponse()
            return response.status, response.read(), dict(response.getheaders())
        finally:
            connection.close()

    assert request('GET', '/health', auth=False)[0] == 200
    assert request('GET', '/v1/jobs', auth=False)[0] == 401
    for path in ('/v1/status', '/v1/jobs', '/v1/channels'):
        code, body, _ = request('GET', path)
        assert code == 200, path
        json.loads(body)
    print('PASS: certificate pin, unauthenticated rejection, authenticated status/jobs/channels')
    if args.video:
        code, _, _ = request('POST', '/v1/jobs', {'id': args.video, 'title': 'Companion verification'})
        assert code == 200
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            code, body, _ = request('GET', '/v1/jobs')
            assert code == 200
            job = next(j for j in json.loads(body) if j['id'] == args.video)
            if job['state'] == 'failed':
                raise RuntimeError('Media preparation failed; inspect the download error in the app')
            if job['state'] == 'ready':
                break
            time.sleep(5)
        else:
            raise RuntimeError('Timed out waiting for real media preparation')
        code, body, headers = request('GET', '/v1/media/' + args.video, headers={'Range': 'bytes=0-1023'})
        assert code == 206 and len(body) == 1024 and b'ftyp' in body[:32]
        assert any(k.lower() == 'content-range' for k in headers)
        print('PASS: real YouTube preparation, MP4 signature, authenticated HTTP Range')


if __name__ == '__main__':
    main()
