#!/usr/bin/env python3
"""Create ignored iOS configuration; preserve existing pairing and signing."""
import argparse
from pathlib import Path
from project_config import setup_ios

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle-id', help='Your unique iOS bundle identifier')
    parser.add_argument('--team', help='Your Apple development team ID')
    args = parser.parse_args()
    try:
        setup_ios(Path(__file__).resolve().parent.parent, args.bundle_id, args.team)
    except ValueError as error:
        parser.error(str(error))
    print('Local iOS configuration ready. Open ios/BetterYouTube.xcodeproj.')
