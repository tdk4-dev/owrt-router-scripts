#!/usr/bin/env python3
"""Exercise the rescue prerequisite boundary without building or signing artifacts."""
import gzip
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DependencyFeeds(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rescue-feeds-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("etc/opkg/keys", "bin", "archive", "tmp", "usr/lib/opkg"):
            (self.root / name).mkdir(parents=True)
        self.write("etc/opkg.conf", "dest root /\noption check_signature\n")
        self.write("etc/opkg/distfeeds.conf", "src/gz baseline https://archive.invalid/base\n")
        self.write("etc/opkg/keys/test-public", "public fixture only\n")
        self.write("etc/openwrt_release", "DISTRIB_RELEASE='24.10.5'\n")
        self.write("usr/lib/opkg/status", "baseline\n")
        self.write("archive/Packages", "Package: ip-full\n\nPackage: conntrack\n\n")
        (self.root / "archive/Packages.gz").write_bytes(gzip.compress((self.root / "archive/Packages").read_bytes()))
        self.write("archive/Packages.sig", hashlib.sha256((self.root / "archive/Packages").read_bytes()).hexdigest())
        self.write("bin/usign", '#!/bin/sh\n[ "${FAIL_SIGNATURE:-0}" = 0 ] || exit 1\nwhile [ "$#" -gt 0 ]; do case "$1" in -m) m="$2"; shift;; -x) x="$2"; shift;; esac; shift; done\n[ "$(sha256sum "$m" | cut -d " " -f1)" = "$(cat "$x")" ]\n', True)
        self.write("bin/opkg-fixture", '''#!/usr/bin/env python3
import os, pathlib, sys
r=pathlib.Path(os.environ['FIXTURE_ROOT']); args=sys.argv[1:]
with (r/'calls').open('a') as f: f.write(' '.join(args)+'\\n')
if '--download-only' in args or 'install' in args:
    assert '-l' in args and '-f' in args, 'opkg must use the pinned feed contract'
    conf=pathlib.Path(args[args.index('-f')+1]).read_text()
    assert 'src baseline https://archive.invalid/base' in conf, 'retained indexes are uncompressed'
    lists=pathlib.Path(args[args.index('-l')+1]); data=(lists/'baseline').read_text()
    assert 'Package: ip-full' in data and 'Package: conntrack' in data
    if os.environ.get('FAIL_DEPENDENCY') == '1': sys.exit(1)
    if '--download-only' not in args:
        (r/'usr/lib/opkg/status').write_text('installed\\n')
        if 'coreutils-nohup' in args:
            p=r/'bin/nohup'; p.write_text('#!/bin/sh\\nexit 0\\n'); p.chmod(0o700)
''', True)
        # Exercise the real function bodies; no production test-only execution branch.
        source = (ROOT / "rescue-router-ui.sh").read_text().split('[ "${ROUTER_UI_TARGET_VERSION')[0]
        self.write("functions.sh", source)
        self.write("run.sh", '''#!/bin/sh
set -eu
. "$FIXTURE_ROOT/functions.sh"
MANIFEST="$FIXTURE_ROOT/manifest"
OPENWRT_RELEASE_FILE="$FIXTURE_ROOT/etc/openwrt_release"
SOURCE_VERSION=0.7.10
OPKG_BIN="$FIXTURE_ROOT/bin/opkg-fixture"
jget() { case "$2" in *size*) echo 100;; esac; }
bridge_state_kib() { echo 1; }
filesystem_free_kib() { echo 999999; }
fetch() { [ "${FAIL_DOWNLOAD:-0}" = 0 ] || return 1; cp "$FIXTURE_ROOT/archive/${1##*/}" "$2"; }
ensure_worker_prerequisite
if [ "${INSTALL_PROJECT:-0}" = 1 ]; then "$VPN_UI_OPKG_BIN" install project-fixture; fi
''', True)
        self.write("manifest", "exact target manifest\n")
        self.env = dict(os.environ, FIXTURE_ROOT=str(self.root), ROUTER_UI_ROOT_PREFIX=str(self.root),
                        PATH=str(self.root / "bin"))
        for tool in ("awk", "cat", "chmod", "cmp", "cp", "cut", "df", "du", "grep", "gzip", "mkdir", "mktemp", "mv", "python3", "rm", "sed", "sh", "sha256sum"):
            (self.root / "bin" / tool).symlink_to(shutil.which(tool))
        self.write("bin/nohup", "#!/bin/sh\nexit 0\n", True)

    def write(self, name, content, executable=False):
        p = self.root / name
        p.write_text(content)
        if executable:
            p.chmod(0o700)

    def run_rescue(self, ok=True, **env):
        p = subprocess.run(["sh", str(self.root / "run.sh")], env=dict(self.env, **env), text=True, capture_output=True)
        self.assertEqual(p.returncode == 0, ok, p.stdout + p.stderr)
        return p

    def test_install_rollback_reboot_reapply_retained_nohup(self):
        (self.root / "bin/nohup").unlink()
        self.run_rescue(INSTALL_PROJECT="1")
        self.assertEqual((self.root / "usr/lib/opkg/status").read_text(), "installed\n")
        self.assertIn('--download-only', (self.root / 'calls').read_text())
        # Rollback restores registration; reboot removes volatile indexes. nohup remains.
        self.write('usr/lib/opkg/status', 'baseline\n')
        shutil.rmtree(self.root / 'tmp')
        (self.root / 'tmp').mkdir()
        # Mutable server content is no longer an authority after the first pin.
        self.write('archive/Packages', 'untrusted replacement\n')
        self.run_rescue(FAIL_DOWNLOAD='1', INSTALL_PROJECT='1')
        self.assertEqual((self.root / 'usr/lib/opkg/status').read_text(), 'installed\n')
        calls = (self.root / 'calls').read_text()
        self.assertEqual(calls.count('--download-only'), 2)
        self.assertIn('ip-full conntrack', calls)

    def test_bad_signature_download_or_dependency_refuses_before_mutation(self):
        for fault in ('FAIL_SIGNATURE', 'FAIL_DOWNLOAD', 'FAIL_DEPENDENCY'):
            with self.subTest(fault=fault):
                self.run_rescue(ok=False, **{fault: '1'})
                self.assertEqual((self.root / 'usr/lib/opkg/status').read_text(), 'baseline\n')
                calls = (self.root / 'calls').read_text() if (self.root / 'calls').exists() else ''
                self.assertTrue(all('--download-only' in line for line in calls.splitlines()))
                shutil.rmtree(self.root / 'root', ignore_errors=True)

    def test_changed_config_or_corrupted_pin_is_not_refreshed(self):
        self.run_rescue()
        self.write('etc/opkg/distfeeds.conf', 'src/gz baseline https://different.invalid/base\n')
        self.run_rescue(ok=False)
        self.write('etc/opkg/distfeeds.conf', 'src/gz baseline https://archive.invalid/base\n')
        lists = list((self.root / 'root').glob('**/lists/baseline'))
        self.assertEqual(len(lists), 1)
        lists[0].write_text('corrupt\n')
        self.run_rescue(ok=False)
        self.assertEqual((self.root / 'calls').read_text().count('--download-only'), 1)


if __name__ == '__main__':
    unittest.main()
