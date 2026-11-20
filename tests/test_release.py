"""Exercise the distribution gate without certificates, Apple services or hardware."""
import copy
import datetime as dt
import importlib.util
from pathlib import Path
import unittest

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release', root / 'scripts/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
TEAM = 'S32Z3HMYVQ'
BUNDLE = 'com.example.driver'
REQUIRED = {'com.apple.developer.driverkit': True}

class DistributionGateTests(unittest.TestCase):
    def setUp(self):
        self.profile = {
            'ExpirationDate': dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=30),
            'ProvisionsAllDevices': True,
            'TeamIdentifier': [TEAM],
            'DeveloperCertificates': [b'synthetic certificate for pure validation only'],
            'Entitlements': {'application-identifier': TEAM + '.' + BUNDLE, **REQUIRED},
        }

    def validate(self, profile=None):
        return release.profile_entitlements(profile or self.profile, BUNDLE, TEAM, REQUIRED)

    def test_valid_distribution(self):
        self.assertTrue(self.validate()['com.apple.developer.driverkit'])

    def test_reject_device_limited(self):
        self.profile['ProvisionedDevices'] = ['example-device']
        with self.assertRaisesRegex(release.ReleaseError, 'device-limited'):
            self.validate()

    def test_reject_not_all_devices(self):
        del self.profile['ProvisionsAllDevices']
        with self.assertRaises(release.ReleaseError): self.validate()

    def test_reject_wrong_team(self):
        self.profile['TeamIdentifier'] = ['OTHER']
        with self.assertRaises(release.ReleaseError): self.validate()

    def test_reject_wrong_app(self):
        self.profile['Entitlements']['application-identifier'] = TEAM + '.com.other.driver'
        with self.assertRaises(release.ReleaseError): self.validate()

    def test_reject_wildcard_app(self):
        self.profile['Entitlements']['application-identifier'] = TEAM + '.*'
        with self.assertRaises(release.ReleaseError): self.validate()

    def test_reject_missing_apple_grant(self):
        del self.profile['Entitlements']['com.apple.developer.driverkit']
        with self.assertRaisesRegex(release.ReleaseError, 'does not grant'): self.validate()

    def test_reject_expired(self):
        self.profile['ExpirationDate'] = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1)
        with self.assertRaisesRegex(release.ReleaseError, 'expired'): self.validate()

    def test_accept_utc_naive_profile_date(self):
        self.profile['ExpirationDate'] = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None) + dt.timedelta(days=1)
        self.validate()

    def test_reject_debugging(self):
        for key in ['get-task-allow', 'com.apple.security.get-task-allow']:
            profile = copy.deepcopy(self.profile)
            profile['Entitlements'][key] = True
            with self.assertRaises(release.ReleaseError): self.validate(profile)

    def test_require_signing_certificate(self):
        self.profile['DeveloperCertificates'] = []
        with self.assertRaises(release.ReleaseError): self.validate()

    def test_apple_identifier_spelling(self):
        ent = self.profile['Entitlements']
        ent['com.apple.application-identifier'] = ent.pop('application-identifier')
        self.validate()

    def test_reject_conflicting_identifiers(self):
        self.profile['Entitlements']['com.apple.application-identifier'] = TEAM + '.wrong'
        with self.assertRaises(release.ReleaseError): self.validate()

    def test_reject_missing_profile_before_build(self):
        class Args:
            host_profile = None
            driver_profile = None
        with self.assertRaisesRegex(release.ReleaseError, 'after distribution approval'):
            release.load_profiles({}, Args())

    def test_8d_only_grant_removes_optional_match(self):
        ent = {'com.apple.developer.driverkit.transport.pci': [{'IOPCIPrimaryMatch': '0x38444452'}]}
        self.assertEqual(release.pci_subset(ent, ['0x38444452', '0x55704452']), ['0x38444452'])

    def test_two_exact_pci_matches(self):
        ent = {'com.apple.developer.driverkit.transport.pci': [{'IOPCIPrimaryMatch': '0x38444452 0x55704452'}]}
        self.assertEqual(len(release.pci_subset(ent, ['0x38444452', '0x55704452'])), 2)

    def test_release_requests_exact_matches_even_if_profile_is_broad(self):
        ent = {'com.apple.developer.driverkit.transport.pci': [{'IOPCIPrimaryMatch': '0x00004452&0x0000ffff'}]}
        self.assertEqual(release.pci_subset(ent, ['0x38444452', '0x55704452']), ['0x38444452', '0x55704452'])

    def test_reject_pci_grant_for_other_hardware(self):
        ent = {'com.apple.developer.driverkit.transport.pci': [{'IOPCIPrimaryMatch': '0x12345678'}]}
        with self.assertRaises(release.ReleaseError): release.pci_subset(ent, ['0x38444452'])

    def test_no_pci_for_usbsmart(self):
        self.assertEqual(release.pci_subset({}, []), [])

class HelperPlistTests(unittest.TestCase):
    APP = 'com.example.app'

    def setUp(self):
        self.plist = {
            'Label': self.APP + '.helper',
            'BundleProgram': 'Contents/MacOS/DroboHelper',
            'MachServices': {self.APP + '.helper': True},
            'AssociatedBundleIdentifiers': [self.APP],
        }

    def check(self):
        release.helper_plist_check(self.plist, self.APP, 'DroboHelper')

    def test_valid(self):
        self.check()

    def test_reject_other_label(self):
        self.plist['Label'] = 'com.other.helper'
        with self.assertRaises(release.ReleaseError): self.check()

    def test_reject_other_program(self):
        self.plist['BundleProgram'] = 'Contents/MacOS/drobo'
        with self.assertRaises(release.ReleaseError): self.check()

    def test_reject_extra_service(self):
        self.plist['MachServices']['com.other.service'] = True
        with self.assertRaises(release.ReleaseError): self.check()

    def test_reject_run_at_load(self):
        self.plist['RunAtLoad'] = True
        with self.assertRaisesRegex(release.ReleaseError, 'RunAtLoad'): self.check()

    def test_spec_writes_a_plist_that_passes(self):
        # The plist is written by a build script in project.yml; expand it the way the shell would.
        import plistlib, re
        spec = (root / 'project.yml').read_text()
        body = re.search(r'<<EOF\n(.*?)\n\s*EOF\n', spec, re.S).group(1)
        text = body.replace('$PRODUCT_BUNDLE_IDENTIFIER', self.APP)
        self.plist = plistlib.loads('\n'.join(line.strip() for line in text.splitlines()).encode())
        self.check()

if __name__ == '__main__':
    unittest.main()
