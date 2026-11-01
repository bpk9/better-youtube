#!/usr/bin/env python3
"""Configure Google sign-in locally without changing companion pairing or shared files."""
import argparse
from pathlib import Path
from project_config import configure_google

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client-id', required=True, help='Google iOS client ID matching your configured bundle identifier')
    args = parser.parse_args()
    try:
        callback = configure_google(Path(__file__).resolve().parent.parent, args.client_id)
    except ValueError as error:
        parser.error(str(error))
    print('Google iOS client configured locally; companion pairing unchanged.')
    print('Callback:', callback)
