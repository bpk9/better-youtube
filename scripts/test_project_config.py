import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from project_config import configure_google, setup_ios

SOURCE = Path(__file__).resolve().parent.parent


class ProjectConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'ios/BetterYouTube').mkdir(parents=True)
        shutil.copytree(SOURCE / 'ios/Config', self.root / 'ios/Config',
                        ignore=shutil.ignore_patterns('Local.xcconfig', 'Google.local.xcconfig'))
        shutil.copy(SOURCE / 'ios/BetterYouTube/Connection.example.plist', self.root / 'ios/BetterYouTube')
        shutil.copy(SOURCE / 'ios/BetterYouTube/Info.plist', self.root / 'ios/BetterYouTube')

    def test_setup_is_generic_and_preserves_local_configuration(self):
        setup_ios(self.root)
        path = self.root / 'ios/BetterYouTube/Connection.plist'
        self.assertEqual(plistlib.loads(path.read_bytes())['GoogleClientID'], '')
        setup_ios(self.root, 'org.example.viewer', 'ABCDEFGHIJ')
        before = (self.root / 'ios/Config/Local.xcconfig').read_bytes()
        setup_ios(self.root)
        self.assertEqual((self.root / 'ios/Config/Local.xcconfig').read_bytes(), before)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_google_configuration_does_not_modify_shared_files_or_pairing(self):
        setup_ios(self.root)
        path = self.root / 'ios/BetterYouTube/Connection.plist'
        pairing = {'ServerURL': 'https://example.invalid:8447', 'ServerToken': 'test-token', 'CertificateSHA256': 'test-pin'}
        path.write_bytes(plistlib.dumps(pairing))
        info = self.root / 'ios/BetterYouTube/Info.plist'
        before = info.read_bytes()
        configure_google(self.root, '123-example.apps.googleusercontent.com')
        callback = configure_google(self.root, '456-replacement.apps.googleusercontent.com')
        actual = plistlib.loads(path.read_bytes())
        self.assertTrue(all(actual[key] == value for key, value in pairing.items()))
        self.assertEqual(info.read_bytes(), before)
        self.assertEqual(callback, 'com.googleusercontent.apps.456-replacement:/oauthredirect')
        self.assertNotIn('123-example', (self.root / 'ios/Config/Google.local.xcconfig').read_text())

    def test_invalid_inputs_do_not_write_local_configuration(self):
        for value in ['bad\nOTHER = value', 'https://example.com']:
            with self.assertRaises(ValueError):
                configure_google(self.root, value)
        with self.assertRaises(ValueError):
            setup_ios(self.root, 'bad\nOTHER = value')
        self.assertFalse((self.root / 'ios/BetterYouTube/Connection.plist').exists())

    def test_pairing_preserves_google_callback_and_existing_token(self):
        setup_ios(self.root)
        configure_google(self.root, '123-example.apps.googleusercontent.com')
        shutil.copytree(SOURCE / 'scripts', self.root / 'scripts', ignore=shutil.ignore_patterns('__pycache__'))
        server = self.root / 'server'; server.mkdir()
        (server / '.env').write_text('BETTER_TOKEN=test-pairing-token\n')
        before = (self.root / 'ios/Config/Google.local.xcconfig').read_bytes()
        result = subprocess.run([sys.executable, str(self.root / 'scripts/prepare-companion.py'), '--host', '127.0.0.1'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = plistlib.loads((self.root / 'ios/BetterYouTube/Connection.plist').read_bytes())
        self.assertEqual(data['ServerToken'], 'test-pairing-token')
        self.assertEqual(data['GoogleClientID'], '123-example.apps.googleusercontent.com')
        self.assertEqual(len(data['CertificateSHA256']), 64)
        self.assertEqual((self.root / 'ios/Config/Google.local.xcconfig').read_bytes(), before)
        self.assertNotIn('test-pairing-token', result.stdout)


if __name__ == '__main__':
    unittest.main()
