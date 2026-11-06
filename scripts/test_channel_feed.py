"""Run the production Swift feed loader against controlled HTTP responses on macOS."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'macOS Swift compiler required')
class ChannelFeedTests(unittest.TestCase):
    def test_uploads_api_and_failure_handling(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            # Compile the real models without the iOS-only views/players that share their files.
            engine = (ROOT / 'ios/BetterYouTube/YouTubeEngine.swift').read_text()
            library = (ROOT / 'ios/BetterYouTube/OfflineLibrary.swift').read_text()
            models = 'import Foundation\nstruct Video:' + engine.split('struct Video:', 1)[1].split('enum FeedTab:', 1)[0]
            models += 'struct ChannelRule:' + library.split('struct ChannelRule:', 1)[1].split('struct DownloadRecord:', 1)[0]
            (work / 'Models.swift').write_text(models)
            binary = work / 'feed-tests'
            compile_result = subprocess.run([
                'swiftc', '-parse-as-library', str(work / 'Models.swift'),
                str(ROOT / 'ios/BetterYouTube/ChannelVideoFeed.swift'),
                str(ROOT / 'scripts/ChannelVideoFeedTests.swift'), '-o', str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main()
