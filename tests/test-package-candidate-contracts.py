#!/usr/bin/env python3
"""Source-only contract tests; fake payload bytes are never built or signed."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('package_contract', ROOT / 'scripts/verify-router-ui-package-candidate.py')
contract = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(contract)


class PackageContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='package-contract-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source'
        self.root.mkdir()
        for path, text in {
            'luci-vpn-ui/VERSION': '0.7.11-rc.22\n',
            'luci-vpn-ui/PACKAGE_VERSION': '0.7.11~rc22-1\n',
            'luci-vpn-ui/files/usr/share/vpn-ui/version': '0.7.11-rc.22\n',
            'release/keys/trusted-keys.json': json.dumps({
                'active_key_id': contract.KEY_ID, 'keys': [{
                    'key_id': contract.KEY_ID, 'fingerprint': contract.FINGERPRINT,
                    'status': 'active'}]})
        }.items():
            p = self.root / path
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Contract Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'nonsecret source fixture')
        self.sha = self.git('rev-parse', 'HEAD')
        self.tree = self.git('rev-parse', 'HEAD^{tree}')

    def verify(self, app='0.7.11-rc.22', package='0.7.11~rc22-1', channel='candidate', **overrides):
        return contract.verify_source(self.root, overrides.get('sha', self.sha),
                                      overrides.get('tree', self.tree), app, package, channel)

    def test_current_candidate_and_future_stable(self):
        identity = self.verify()
        self.assertEqual(identity['source_tree'], self.tree)
        self.assertFalse(identity['vm_qualified'])
        self.assertFalse(identity['publication_authorized'])
        for name, value in [('VERSION', '0.7.11'), ('PACKAGE_VERSION', '0.7.11-1'),
                            ('files/usr/share/vpn-ui/version', '0.7.11')]:
            (self.root / 'luci-vpn-ui' / name).write_text(value + '\n')
        self.commit()
        self.assertEqual(self.verify('0.7.11', '0.7.11-1', 'stable')['channel'], 'stable')

    def test_mismatched_historical_and_mixed_tuples(self):
        for args in [('0.7.11-rc.15', '0.7.11~rc15-1', 'candidate'),
                     ('0.7.11-rc.22', '0.7.11-1', 'candidate'),
                     ('0.7.11-rc.22', '0.7.11~rc22-1', 'stable'),
                     ('0.7.11', '0.7.11-1', 'stable')]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                self.verify(*args)

    def test_exact_source_and_clean_checkout(self):
        for kw in ({'sha': 'a' * 40}, {'sha': 'main'}, {'tree': 'b' * 40}):
            with self.subTest(kw=kw), self.assertRaises(ValueError):
                self.verify(**kw)
        (self.root / 'untracked').write_text('fixture')
        with self.assertRaisesRegex(ValueError, 'clean'):
            self.verify()

    def test_version_marker_and_active_key_boundaries(self):
        marker = self.root / 'luci-vpn-ui/files/usr/share/vpn-ui/version'
        marker.write_text('0.7.11-rc.15\n')
        self.commit()
        with self.assertRaisesRegex(ValueError, 'version mismatch'):
            self.verify()
        marker.write_text('0.7.11-rc.22\n')
        registry_file = self.root / 'release/keys/trusted-keys.json'
        registry = json.loads(registry_file.read_text())
        for status, fingerprint in [('previous', contract.FINGERPRINT),
                                    ('revoked', contract.FINGERPRINT), ('active', '0' * 16)]:
            registry['keys'][0].update(status=status, fingerprint=fingerprint)
            registry_file.write_text(json.dumps(registry))
            self.commit()
            with self.subTest(status=status), self.assertRaises(ValueError):
                self.verify()

    def release_fixture(self):
        identity = self.verify()
        release = Path(self.temp.name) / 'release'
        release.mkdir()
        packages = []
        for name in contract.PACKAGES:
            filename = f'{name}_{identity["package_version"]}_all.ipk'
            data = b'FAKE CONTRACT FIXTURE: NOT AN INSTALLABLE PACKAGE\n'
            (release / filename).write_bytes(data)
            packages.append(dict(name=name, filename=filename, size=len(data),
                                 sha256=hashlib.sha256(data).hexdigest()))
        manifest = dict(app_version=identity['app_version'], package_version=identity['package_version'],
                        signing_key_id=contract.KEY_ID, signing_key_fingerprint=contract.FINGERPRINT,
                        source_commit=self.sha, source_dirty=False, channel='candidate', images=[],
                        release_tag='vpn-panel-v0.7.11-rc.22', packages=packages)
        provenance = dict(manifest, derived_images=[])
        (release / 'router-release-manifest.json').write_text(json.dumps(manifest))
        (release / 'release-provenance.json').write_text(json.dumps(provenance))
        return release, identity, manifest, provenance

    def test_package_scope_and_hash_boundaries(self):
        release, identity, manifest, _ = self.release_fixture()
        self.assertEqual(len(contract.verify_package_only(release, identity)), 3)
        for filename in ('extra.ipk', 'firmware.bin', 'factory-router-release-manifest.json',
                         'factory-release-contract.json.sig', 'image-package-manifest.json',
                         'unknown.txt', 'guest.vdi', 'guest.vmdk', 'guest.qcow2',
                         'premier-router-0.7.11-openwrt-24.10.5-x86.tar.gz'):
            p = release / filename
            p.write_text('not an artifact')
            with self.subTest(filename=filename), self.assertRaises(ValueError):
                contract.verify_package_only(release, identity)
            p.unlink()
        p = release / manifest['packages'][0]['filename']
        original = p.read_bytes()
        p.write_bytes(original + b'tamper')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            contract.verify_package_only(release, identity)
        p.unlink()
        with self.assertRaisesRegex(ValueError, 'three expected'):
            contract.verify_package_only(release, identity)

    def test_metadata_cannot_change_scope_or_source(self):
        release, identity, manifest, provenance = self.release_fixture()
        for field, value in [('images', [{}]), ('source_commit', 'b' * 40),
                             ('source_dirty', True), ('channel', 'stable'),
                             ('signing_key_id', 'test-key'), ('signing_key_fingerprint', '0' * 16)]:
            altered = dict(manifest, **{field: value})
            (release / 'router-release-manifest.json').write_text(json.dumps(altered))
            with self.subTest(field=field), self.assertRaises(ValueError):
                contract.verify_package_only(release, identity)
        (release / 'router-release-manifest.json').write_text(json.dumps(manifest))
        provenance['derived_images'] = [{}]
        (release / 'release-provenance.json').write_text(json.dumps(provenance))
        with self.assertRaisesRegex(ValueError, 'images'):
            contract.verify_package_only(release, identity)

    def test_signature_inputs_cannot_be_missing_empty_or_wrong_channel(self):
        release, _, _, _ = self.release_fixture()
        # Deliberately invalid fixture bytes. This test proves presence and channel
        # selection only, never cryptographic validity or production qualification.
        for name in ('router-release-manifest.json', 'release-provenance.json', 'SHA256SUMS',
                     'installed-manifest.json', 'candidate-channel.json'):
            for filename in (name, name + '.sig'):
                (release / filename).write_text('FAKE NONCRYPTOGRAPHIC CONTRACT FIXTURE\n')
        contract.require_signature_inputs(release, 'candidate')
        signature = release / 'candidate-channel.json.sig'
        signature.rename(release / 'stable-channel.json.sig')
        with self.assertRaisesRegex(ValueError, 'candidate-channel.json.sig'):
            contract.require_signature_inputs(release, 'candidate')
        signature.write_text('')
        with self.assertRaisesRegex(ValueError, 'empty signature'):
            contract.require_signature_inputs(release, 'candidate')
        signature.unlink()
        signature.symlink_to(release / 'stable-channel.json.sig')
        with self.assertRaisesRegex(ValueError, 'signature input'):
            contract.require_signature_inputs(release, 'candidate')


if __name__ == '__main__':
    unittest.main()
