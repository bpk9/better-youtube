import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import urlsplit

from project_config import configure_google, setup_ios

SOURCE = Path(__file__).resolve().parent.parent


class ProjectConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'ios/BetterYouTube').mkdir(parents=True)
        shutil.copytree(SOURCE / 'ios/Config', self.root / 'ios/Config',
                        ignore=shutil.ignore_patterns('*.local.xcconfig', 'Local.xcconfig'))
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

    def prepare(self, *args):
        if not (self.root / 'scripts').exists():
            shutil.copytree(SOURCE / 'scripts', self.root / 'scripts', ignore=shutil.ignore_patterns('__pycache__'))
        (self.root / 'server').mkdir(exist_ok=True)
        return subprocess.run([sys.executable, str(self.root / 'scripts/prepare-companion.py'), *args],
                              capture_output=True, text=True)

    def test_magicdns_pairing_separates_app_host_from_docker_bind(self):
        result = self.prepare('--host', 'companion.example.ts.net', '--bind-ip', '100.101.102.103')
        self.assertEqual(result.returncode, 0, result.stderr)
        config = plistlib.loads((self.root / 'ios/BetterYouTube/Connection.plist').read_bytes())
        self.assertEqual(config['ServerURL'], 'https://companion.example.ts.net:8447')
        self.assertIn('BETTER_BIND_IP=100.101.102.103\n', (self.root / 'server/.env').read_text())
        self.assertEqual((self.root / 'ios/Config/Companion.local.xcconfig').read_text(),
                         'BETTER_COMPANION_HOST = companion.example.ts.net\n')
        san = subprocess.check_output(['openssl', 'x509', '-in', str(self.root / 'server/tls/cert.pem'),
                                       '-noout', '-text'], text=True)
        self.assertIn('DNS:companion.example.ts.net', san)

    def test_migration_preserves_certificate_token_google_and_server_settings(self):
        result = self.prepare('--host', '127.0.0.1')
        self.assertEqual(result.returncode, 0, result.stderr)
        configure_google(self.root, '123-example.apps.googleusercontent.com')
        env = self.root / 'server/.env'
        env.write_text(env.read_text().replace('BETTER_POLL_SECONDS=1800', 'BETTER_POLL_SECONDS=3600')
                       + 'BETTER_CUSTOM_SETTING=preserved\n')
        cert = (self.root / 'server/tls/cert.pem').read_bytes()
        key = (self.root / 'server/tls/key.pem').read_bytes()
        path = self.root / 'ios/BetterYouTube/Connection.plist'
        before = plistlib.loads(path.read_bytes())
        result = self.prepare('--host', 'companion.example.ts.net', '--bind-ip', '100.101.102.103',
                              '--reuse-certificate')
        self.assertEqual(result.returncode, 0, result.stderr)
        after = plistlib.loads(path.read_bytes())
        for field in ('ServerToken', 'CertificateSHA256', 'GoogleClientID'):
            self.assertEqual(after[field], before[field])
        self.assertEqual((self.root / 'server/tls/cert.pem').read_bytes(), cert)
        self.assertEqual((self.root / 'server/tls/key.pem').read_bytes(), key)
        self.assertIn('BETTER_POLL_SECONDS=3600\n', env.read_text())
        self.assertIn('BETTER_CUSTOM_SETTING=preserved\n', env.read_text())
        self.assertNotIn(before['ServerToken'], result.stdout + result.stderr)

    def test_tailscale_ip_pairing_handles_both_address_families(self):
        for host in ('100.101.102.103', 'fd7a:115c:a1e0::1'):
            result = self.prepare('--host', host)
            self.assertEqual(result.returncode, 0, result.stderr)
            config = plistlib.loads((self.root / 'ios/BetterYouTube/Connection.plist').read_bytes())
            self.assertEqual(urlsplit(config['ServerURL']).hostname, host)
            self.assertEqual(urlsplit(config['ServerURL']).port, 8447)
            self.assertIn(f'BETTER_BIND_IP={host}\n', (self.root / 'server/.env').read_text())
            self.assertEqual((self.root / 'ios/Config/Companion.local.xcconfig').read_text(),
                             'BETTER_COMPANION_HOST = localhost\n')

    def test_invalid_pairing_arguments_leave_existing_configuration_untouched(self):
        result = self.prepare('--host', '127.0.0.1')
        self.assertEqual(result.returncode, 0, result.stderr)
        paths = ['server/.env', 'server/tls/cert.pem', 'server/tls/key.pem',
                 'ios/BetterYouTube/Connection.plist', 'ios/Config/Companion.local.xcconfig']
        before = {path: (self.root / path).read_bytes() for path in paths}
        for args in [('--host', 'companion.example.ts.net'),
                     ('--host', 'https://companion.example.ts.net', '--bind-ip', '100.101.102.103'),
                     ('--host', 'bad\nOTHER = value', '--bind-ip', '100.101.102.103'),
                     ('--host', 'companion.example.ts.net', '--bind-ip', '0.0.0.0'),
                     ('--host', 'companion.example.ts.net', '--bind-ip', '::'),
                     ('--host', 'companion.example.ts.net', '--bind-ip', 'not-an-ip')]:
            with self.subTest(args=args):
                self.assertNotEqual(self.prepare(*args).returncode, 0)
                self.assertEqual({path: (self.root / path).read_bytes() for path in paths}, before)

    def test_reuse_requires_existing_certificate_and_key(self):
        result = self.prepare('--host', '100.101.102.103', '--reuse-certificate')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'server/.env').exists())
        self.assertFalse((self.root / 'ios/BetterYouTube/Connection.plist').exists())

    def test_setup_restores_exact_dns_exception_from_existing_pairing(self):
        setup_ios(self.root)
        path = self.root / 'ios/BetterYouTube/Connection.plist'
        path.write_bytes(plistlib.dumps({'ServerURL': 'https://companion.example.ts.net:8447'}))
        setup_ios(self.root)
        self.assertEqual((self.root / 'ios/Config/Companion.local.xcconfig').read_text(),
                         'BETTER_COMPANION_HOST = companion.example.ts.net\n')

    @unittest.skipUnless(shutil.which('cc'), 'Requires a C preprocessor, as used by Xcode')
    def test_ats_template_preprocesses_the_exact_hostname_key(self):
        processed = subprocess.check_output(['cc', '-E', '-P', '-x', 'c',
            '-DBETTER_COMPANION_HOST=companion.example.ts.net',
            str(self.root / 'ios/BetterYouTube/Info.plist')])
        ats = plistlib.loads(processed)['NSAppTransportSecurity']
        self.assertEqual(ats['NSExceptionDomains'], {
            'companion.example.ts.net': {'NSExceptionAllowsInsecureHTTPLoads': True}})
        self.assertFalse(any(value for key, value in ats.items() if key.startswith('NSAllowsArbitraryLoads')))


if __name__ == '__main__':
    unittest.main()
