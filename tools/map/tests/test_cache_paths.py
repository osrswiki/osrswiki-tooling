import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from cache_paths import find_cache_base


class CachePathTests(unittest.TestCase):
    def storage_env(self, temp_dir, root):
        home = Path(temp_dir) / "home"
        home.mkdir(exist_ok=True)
        return {
            "HOME": str(home),
            "OSRS_LOCAL_ARTIFACT_ROOT": str(root),
            "OSRS_ARTIFACT_HOST_ID": "test-home",
            "OSRS_LOCAL_STORAGE_CONFIG": str(home / "missing-storage.env"),
        }

    def test_prefers_configured_machine_local_cache(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            local_cache = Path(temp_dir) / "local-artifacts" / "cache"
            source_tree = Path(temp_dir) / "Documents" / "osrswiki" / "main"
            local_cache.mkdir(parents=True)
            source_tree.mkdir(parents=True)

            env = self.storage_env(temp_dir, local_cache.parent)
            env["OSRS_CACHE_ROOT"] = str(local_cache)
            with mock.patch.dict(os.environ, env):
                self.assertEqual(local_cache.resolve(), find_cache_base(source_tree))

    def test_rejects_missing_configured_cache(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "local-artifacts"
            missing = root / "missing-cache"
            root.mkdir()
            env = self.storage_env(temp_dir, root)
            env["OSRS_CACHE_ROOT"] = str(missing)
            with mock.patch.dict(os.environ, env):
                with self.assertRaisesRegex(RuntimeError, "does not exist"):
                    find_cache_base(Path(temp_dir))

    def test_initializes_configured_local_cache_from_any_checkout(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "local-artifacts"
            source_tree = Path(temp_dir) / "Documents" / "osrswiki" / "main"
            source_tree.mkdir(parents=True)

            with mock.patch.dict(os.environ, self.storage_env(temp_dir, root)):
                self.assertEqual((root / "cache").resolve(), find_cache_base(source_tree))
                self.assertTrue((root / "cache").is_dir())

    def test_rejects_cache_override_outside_verified_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "local-artifacts"
            outside = Path(temp_dir) / "Documents" / "cache"
            root.mkdir()
            outside.mkdir(parents=True)
            env = self.storage_env(temp_dir, root)
            env["OSRS_CACHE_ROOT"] = str(outside)

            with mock.patch.dict(os.environ, env):
                with self.assertRaisesRegex(RuntimeError, "outside the verified local root"):
                    find_cache_base(Path(temp_dir))


if __name__ == "__main__":
    unittest.main()
