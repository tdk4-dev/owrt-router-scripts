#!/usr/bin/env python3
"""Source-only execution of the package provisioning/security boundaries."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CleanProvisioning(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        for path in ('etc/config', 'etc/xray', 'etc/init.d', 'tmp', 'bin', 'control'):
            (self.root / path).mkdir(parents=True)
        self.config = self.root / 'etc/config/xray'
        self.stock = "\n".join((
            'xray.enabled=xray', "xray.enabled.enabled='0'", 'xray.config=xray',
            "xray.config.confdir='/etc/xray'", "xray.config.conffiles='/etc/xray/config.json'",
            "xray.config.datadir='/usr/share/xray'", "xray.config.format='json'", ''))
        self.config.write_text(self.stock)
        self.config.chmod(0o600)
        (self.root / 'etc/xray/config.json.example').write_text('upstream example')
        mock = self.root / 'bin/uci'
        mock.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
p=pathlib.Path(os.environ['FIXTURE_ROOT'])/'etc/config/xray'
a=sys.argv[1:]
if a[:1]==['-q']:a=a[1:]
if a[0]=='changes':print(os.environ.get('PENDING',''));sys.exit(1 if os.environ.get('FAIL_READ') else 0)
if a[0]=='show':print(p.read_text(),end='');sys.exit(0)
if a[0]=='revert':sys.exit(0)
if a[0]=='commit':sys.exit(1 if os.environ.get('FAIL_COMMIT') else 0)
lines=p.read_text().splitlines()
if a[0]=='delete':lines=[l for l in lines if not l.startswith(a[1]+'=')]
elif a[0]=='set':
 key,val=a[1].split('=',1);lines=[l for l in lines if not l.startswith(key+'=')];lines.append(key+"='"+val+"'")
else:sys.exit(2)
p.write_text('\\n'.join(lines)+'\\n')
''')
        mock.chmod(0o755)
        (self.root / 'bin/pidof').write_text('#!/bin/sh\n[ "${RUNNING:-0}" = 1 ] && echo 123\n')
        (self.root / 'bin/pidof').chmod(0o755)
        self.env = dict(os.environ, FIXTURE_ROOT=str(self.root),
                        PATH=str(self.root / 'bin') + ':' + os.environ['PATH'])

    def initialize(self, **env):
        return subprocess.run(['sh', '-c', '. "$1"; pr_initialize_clean_native_xray "$2"',
                               'test', str(ROOT / 'scripts/package-native-init.sh'), str(self.root)],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def test_stock_becomes_native_without_seeding_historical_state(self):
        r = self.initialize()
        self.assertEqual(r.returncode, 0, r.stderr)
        text = self.config.read_text()
        self.assertIn("xray.config.conffiles='/etc/xray/exit-st-cf.json'", text)
        self.assertNotIn('confdir=', text)
        self.assertIn("xray.enabled.enabled='0'", text)
        self.assertFalse((self.root / 'etc/xray/exit-st-cf.json').exists())
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        before = self.config.read_bytes()
        self.assertEqual(self.initialize().returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)

    def test_existing_config_profiles_ownership_and_custom_uci_are_preserved(self):
        for path in ('etc/xray/config.json', 'etc/xray/exit-st-cf.json',
                     'etc/xray/vless-profiles.d', 'etc/premier-router/xray-ownership.json',
                     'etc/init.d/xray-exit-st', 'etc/firstboot-wizard/complete'):
            with self.subTest(path=path):
                p = self.root / path; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('existing')
                self.assertEqual(self.initialize().returncode, 0)
                self.assertEqual(self.config.read_text(), self.stock)
                p.unlink()
        self.config.write_text(self.stock.replace('/etc/xray/config.json', '/etc/xray/custom.json'))
        before = self.config.read_bytes(); self.assertEqual(self.initialize().returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)

    def test_running_daemon_or_pending_uci_is_untouched(self):
        for env in ({'RUNNING':'1'}, {'PENDING':'xray.config.foo=bar'}):
            self.assertEqual(self.initialize(**env).returncode, 0)
            self.assertEqual(self.config.read_text(), self.stock)

    def test_failure_restores_config_and_mode(self):
        for env in ({'FAIL_COMMIT':'1'}, {'FAIL_READ':'1'}):
            self.assertNotEqual(self.initialize(**env).returncode, 0)
            self.assertEqual(self.config.read_text(), self.stock)
            self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_symlink_is_not_followed(self):
        target = self.root / 'outside'; target.write_text(self.stock)
        self.config.unlink(); self.config.symlink_to(target)
        self.assertEqual(self.initialize().returncode, 0)
        self.assertEqual(target.read_text(), self.stock)

    def test_online_package_guard_is_not_a_completion_marker(self):
        builder = (ROOT / 'scripts/build-openwrt-ipks.sh').read_text()
        fn = 'write_setup_scripts() {' + builder.split('write_setup_scripts() {', 1)[1].split('\nwrite_legacy_manifest()', 1)[0]
        writer = self.root / 'writer.sh'
        writer.write_text('ROOT_DIR="' + str(ROOT) + '"\n' + fn + '\nwrite_setup_scripts "$1"\n')
        subprocess.run(['sh', str(writer), str(self.root / 'control')], check=True)
        preinst = (self.root / 'control/preinst').read_text().replace(
            'STATE_DIR=/etc/firstboot-wizard', 'STATE_DIR=' + str(self.root / 'etc/firstboot-wizard'))
        p = self.root / 'preinst'; p.write_text(preinst)
        subprocess.run(['sh', str(p)], env=dict(self.env, IPKG_INSTROOT=str(self.root)), check=True)
        self.assertFalse((self.root / 'etc/firstboot-wizard').exists())
        subprocess.run(['sh', str(p)], check=True)
        state = self.root / 'etc/firstboot-wizard'
        self.assertFalse((state / 'complete').exists())
        self.assertTrue((state / 'package-install').is_file())
        self.assertEqual((state / 'package-install').stat().st_mode & 0o777, 0o600)
        cgi = (ROOT / 'image-overlay/www/cgi-bin/firstboot-setup').read_text().replace(
            'STATE_DIR="/etc/firstboot-wizard"', 'STATE_DIR="' + str(state) + '"')
        p.write_text(cgi)
        r = subprocess.run(['sh', str(p)], env=dict(self.env, QUERY_STRING='action=apply', CONTENT_LENGTH='0'),
                           capture_output=True, text=True)
        self.assertIn('authenticated LuCI', r.stdout)
        self.assertIn('"ok":false', r.stdout)
        (state / 'complete').write_text('existing completion')
        p.write_text(preinst); subprocess.run(['sh', str(p)], check=True)
        self.assertEqual((state / 'complete').read_text(), 'existing completion')

    def test_bootstrap_guard_preserves_completion_and_refuses_symlinks(self):
        source = (ROOT / 'bootstrap-router-ui-ipk-install.sh').read_text()
        fn = 'guard_package_setup() {' + source.split('guard_package_setup() {', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
        state = self.root / 'etc/firstboot-wizard'
        script = self.root / 'guard.sh'
        script.write_text('set -eu\nFIRSTBOOT_STATE_DIR="' + str(state) + '"\n'
                          'FIRSTBOOT_PACKAGE_GUARD="$FIRSTBOOT_STATE_DIR/package-install"\n'
                          'die() { exit 1; }\n' + fn + '\nguard_package_setup\n')
        subprocess.run(['sh', str(script)], check=True)
        self.assertFalse((state / 'complete').exists())
        (state / 'complete').write_text('previous setup')
        subprocess.run(['sh', str(script)], check=True)
        self.assertEqual((state / 'complete').read_text(), 'previous setup')
        (state / 'package-install').unlink()
        (state / 'package-install').symlink_to(self.config)
        self.assertNotEqual(subprocess.run(['sh', str(script)]).returncode, 0)
        self.assertEqual(self.config.read_text(), self.stock)


if __name__ == '__main__':
    unittest.main()
