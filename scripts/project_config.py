"""Local configuration for the iOS client; never edits shared project files."""
from __future__ import annotations

import os
from pathlib import Path
import plistlib
import re


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
