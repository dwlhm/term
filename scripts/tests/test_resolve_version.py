import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from resolve_version import BuildVersion, VersionError, resolve_version, write_outputs


class ResolverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "term@example.invalid")
        self.git("config", "user.name", "Term Test")
        self.commit_file("tracked", "initial")

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.root), *args],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def commit_file(self, name, content):
        (self.root / name).write_text(content)
        self.git("add", name)
        self.git("commit", "-qm", content)

    def test_clean_exact_tag_is_release_version(self):
        self.git("tag", "v2.4.6")
        version = resolve_version(self.root, "v2.4.6")
        self.assertEqual((version.runtime, version.numeric, version.dirty), ("2.4.6", "2.4.6", False))

    def test_dev_version_uses_distance_and_hash(self):
        self.git("tag", "v2.4.6")
        self.commit_file("next", "next")
        version = resolve_version(self.root)
        self.assertEqual(version.runtime, f"2.4.6-dev.1+g{self.git('rev-parse', '--short=7', 'HEAD')}")

    def test_no_tag_uses_zero_base_and_hash(self):
        version = resolve_version(self.root)
        self.assertEqual(version.runtime, f"0.0.0-dev+g{self.git('rev-parse', '--short=7', 'HEAD')}")

    def test_dirty_checkout_is_marked_and_not_release(self):
        self.git("tag", "v2.4.6")
        (self.root / "tracked").write_text("modified")
        version = resolve_version(self.root)
        self.assertTrue(version.runtime.endswith(".dirty"))
        self.assertTrue(version.dirty)
        with self.assertRaises(VersionError):
            resolve_version(self.root, "v2.4.6")

    def test_invalid_release_tag_fails_closed(self):
        with self.assertRaises(VersionError):
            resolve_version(self.root, "v2.4")

    def test_missing_release_metadata_fails_closed(self):
        with self.assertRaises(VersionError):
            resolve_version(self.root / "missing", "v2.4.6")
        with self.assertRaises(VersionError):
            resolve_version(self.root, "v2.4.6")

    def test_missing_local_git_metadata_uses_unknown(self):
        version = resolve_version(self.root / "missing")
        self.assertEqual(version.runtime, "0.0.0-dev+unknown")
        self.assertEqual(version.numeric, "0.0.0")

    def test_generated_bundle_has_numeric_versions_and_preserves_other_keys(self):
        template = plistlib.loads(Path("assets/Info.plist").read_bytes())
        source = self.root / "generated" / "version.odin"
        plist = self.root / "generated" / "Info.plist"
        write_outputs(BuildVersion("2.4.6-dev.3+gabcdef0", "2.4.6", True), source, plist)
        generated = plistlib.loads(plist.read_bytes())
        self.assertEqual(generated["CFBundleShortVersionString"], "2.4.6")
        self.assertEqual(generated["CFBundleVersion"], "2.4.6")
        self.assertEqual({key: value for key, value in generated.items() if key not in {"CFBundleShortVersionString", "CFBundleVersion"}},
                         {key: value for key, value in template.items() if key not in {"CFBundleShortVersionString", "CFBundleVersion"}})
        self.assertIn('VERSION :: "2.4.6-dev.3+gabcdef0"', source.read_text())


if __name__ == "__main__":
    unittest.main()
