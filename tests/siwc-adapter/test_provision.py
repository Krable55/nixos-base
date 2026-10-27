import importlib.util
import os
from pathlib import Path
import tempfile
import tomllib
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'packages/siwc-adapter/provision.py'


class Provision(unittest.TestCase):
    def test_distinct_owners_cannot_read_each_others_capability(self):
        if os.getuid() != 0:
            self.skipTest('requires mapped-root namespace with subordinate IDs')
        spec = importlib.util.spec_from_file_location('provision', SOURCE)
        p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
        with tempfile.TemporaryDirectory() as d:
            Path(d).chmod(0o711)
            root = Path(d) / 'runtime'; template = Path(d) / 'template'
            template.write_text('api_key = "@CAPABILITY@"\n')
            p.provision(root, template, (1, 1), (2, 2))
            pid = os.fork()
            if pid == 0:
                os.setgroups([]); os.setgid(2); os.setuid(2)
                allowed = os.access(root / 'agent/config.toml', os.R_OK)
                denied = not os.access(root / 'adapter/capability', os.R_OK)
                master_denied = not os.access(root / 'capability', os.R_OK)
                os._exit(0 if allowed and denied and master_denied else 1)
            self.assertEqual(os.waitpid(pid, 0)[1], 0)
            self.assertEqual((root / 'adapter/capability').stat().st_uid, 1)
            self.assertEqual((root / 'agent/config.toml').stat().st_uid, 2)

    def test_stable_private_runtime_publication(self):
        self.assertTrue(SOURCE.exists(), 'runtime provisioner is missing')
        spec = importlib.util.spec_from_file_location('provision', SOURCE)
        p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / 'runtime'
            template = Path(d) / 'template.toml'
            template.write_text('schema_version = 3\n[providers.models.openai.siwc]\napi_key = "@CAPABILITY@"\n')
            ids = (os.getuid(), os.getgid())
            p.provision(root, template, ids, ids)
            a = root / 'adapter/capability'; c = root / 'agent/config.toml'
            token = a.read_text().strip()
            self.assertGreaterEqual(len(token), 32)
            self.assertEqual(tomllib.loads(c.read_text())['providers']['models']['openai']['siwc']['api_key'], token)
            for f in (root / 'capability', a, c):
                self.assertEqual(f.stat().st_mode & 0o777, 0o600)
                self.assertEqual(f.stat().st_uid, os.getuid())
            self.assertEqual(root.stat().st_mode & 0o777, 0o711)
            self.assertEqual(a.parent.stat().st_mode & 0o777, 0o750)
            p.provision(root, template, ids, ids)
            self.assertEqual(a.read_text().strip(), token, 'restart rotated capability')
            a.unlink(); a.symlink_to(template)
            with self.assertRaises(RuntimeError):
                p.provision(root, template, ids, ids)
            self.assertIn('@CAPABILITY@', template.read_text())


if __name__ == '__main__': unittest.main()
