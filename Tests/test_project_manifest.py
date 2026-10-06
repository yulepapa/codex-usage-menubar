"""Public metadata must describe the behavior covered by the reset engine tests."""
import json
from pathlib import Path
import plistlib
import unittest


PROJECT = Path(__file__).resolve().parent.parent


class ProjectManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((PROJECT / 'project-manifest.json').read_text())

    def test_time_only_eligibility_contract(self):
        runtime = self.manifest['runtime']
        # ResetEngineTests exercises this boundary at 0/8/30/100% remaining,
        # including absent usage windows. No consumer should infer a usage gate.
        self.assertEqual(runtime['autoUseBeforeExpirySeconds'], 1200)
        self.assertIs(runtime['usagePercentagesAffectEligibility'], False)
        self.assertNotIn('maximumRemainingPercentForEligibility', runtime)

    def test_release_version_matches_bundle_and_readme(self):
        info = plistlib.loads((PROJECT / 'Resources/Info.plist').read_bytes())
        version = self.manifest['version']
        self.assertEqual(version, info['CFBundleShortVersionString'])
        self.assertIn(f'현재 버전 **{version}**', (PROJECT / 'README.md').read_text())
        self.assertIn(f'## {version} —', (PROJECT / 'CHANGELOG.md').read_text())


if __name__ == '__main__':
    unittest.main()
