"""Local configuration for the iOS client; never edits shared project files."""
from __future__ import annotations

import os
import ipaddress
from pathlib import Path
import plistlib
import re
from urllib.parse import urlsplit


def companion_host(host: str) -> str:
    """Accept a bare IP or ASCII DNS name, never a URL, port, or config text."""
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        host = host.lower().removesuffix('.')
        if len(host) > 253 or not re.fullmatch(
            r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*', host
        ):
            raise ValueError('Use a bare IP address or hostname, without a scheme or port.')
        return host
    if address.is_unspecified or address.is_multicast or '%' in host:
        raise ValueError('Use a specific unicast IP address for the companion.')
    return str(address)


def configure_companion_ats(root: Path) -> None:
    """Allow manual certificate pinning only for the paired DNS host."""
    connection = plistlib.loads((root / 'ios/BetterYouTube/Connection.plist').read_bytes())
    host = urlsplit(connection.get('ServerURL', '')).hostname
    exception_host = 'localhost'
    if host:
        host = companion_host(host)
        try:
            ipaddress.ip_address(host)
        except ValueError:
            exception_host = host
    config = root / 'ios/Config/Companion.local.xcconfig'
    config.write_text(f'BETTER_COMPANION_HOST = {exception_host}\n')
    os.chmod(config, 0o600)


def setup_ios(root: Path, bundle_id: str | None = None, team: str | None = None) -> None:
    if bundle_id is not None and not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id):
        raise ValueError('Use a reverse-DNS bundle identifier, such as com.example.betteryoutube.')
    if team is not None and not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Use the 10-character Apple development team ID.')
    ios = root / 'ios'
    connection = ios / 'BetterYouTube/Connection.plist'
    if not connection.exists():
        connection.write_bytes((ios / 'BetterYouTube/Connection.example.plist').read_bytes())
        os.chmod(connection, 0o600)
    configure_companion_ats(root)
    local = ios / 'Config/Local.xcconfig'
    text = local.read_text() if local.exists() else '// Local signing overrides; excluded from source control.\n'
    for key, value in [('BETTER_BUNDLE_ID', bundle_id), ('DEVELOPMENT_TEAM', team)]:
        if value is None:
            continue
        line = f'{key} = {value}'
        pattern = rf'^{key}\s*=.*$'
        text = re.sub(pattern, line, text, flags=re.M) if re.search(pattern, text, re.M) else text + line + '\n'
    local.write_text(text)
    os.chmod(local, 0o600)


def validate_client(client_id: str) -> str:
    client_id = client_id.strip()
    if not re.fullmatch(r'[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com', client_id):
        raise ValueError('Expected an iOS OAuth client ID from Google Cloud.')
    return client_id


def configure_google(root: Path, client_id: str) -> str:
    client_id = validate_client(client_id)
    setup_ios(root)
    connection_path = root / 'ios/BetterYouTube/Connection.plist'
    connection = plistlib.loads(connection_path.read_bytes())
    connection['GoogleClientID'] = client_id
    connection_path.write_bytes(plistlib.dumps(connection))
    os.chmod(connection_path, 0o600)
    scheme = '.'.join(reversed(client_id.split('.')))
    callback_config = root / 'ios/Config/Google.local.xcconfig'
    callback_config.write_text(f'GOOGLE_REVERSED_CLIENT_ID = {scheme}\n')
    os.chmod(callback_config, 0o600)
    return scheme + ':/oauthredirect'
