"""Check persistent swap policy with fake swap/sysctl, without host changes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'tune.sh').read_text()
POLICY = SOURCE.split('# -- Swap policy (also exercised independently by tests)', 1)[1]
POLICY = POLICY.split('\n', 1)[1].split('# -- End swap policy', 1)[0]
CONFIG = SOURCE.split('SWAPPINESS=', 1)[1].split('# --- TCP stack', 1)[0]
CONFIG = 'SWAPPINESS=' + CONFIG


class SwapPolicyTest(unittest.TestCase):
    def run_policy(self, root, *, dry=False, swap='/dev/zram0'):
        script = '''set -euo pipefail
SYSCTL_D="$TEST_ROOT"
SWAP_CONF="$SYSCTL_D/99-swap.conf"
swapon() { printf '%s' "$TEST_SWAP"; }
sysctl() { printf '%s\\n' "$*" >> "$TEST_ROOT/sysctl.calls"; }
skip() { :; }
c() { if [[ "$DRY_RUN" -eq 0 ]]; then "$@"; fi; }
'''
        env = dict(os.environ, TEST_ROOT=str(root), TEST_SWAP=swap)
        subprocess.run(['bash', '-c', script + CONFIG +
                        f'\nDRY_RUN={int(dry)}\n' + POLICY], env=env,
                       check=True, capture_output=True, text=True)

    def test_missing_keys_and_whitespace_duplicates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            conf = root / '99-swap.conf'
            conf.write_text('# keep comment\nvm.dirty_ratio=30\n'
                            '  vm.swappiness = 0\nvm.swappiness=1\n')
            self.run_policy(root)
            expected = ('# keep comment\nvm.dirty_ratio=30\n'
                        'vm.swappiness=60\nvm.page-cluster=0\n'
                        'vm.watermark_scale_factor=150\n')
            self.assertEqual(conf.read_text(), expected)
            self.assertIn('vm.watermark_scale_factor=150',
                          (root / 'sysctl.calls').read_text())
            before = conf.stat().st_mtime_ns
            self.run_policy(root)
            self.assertEqual(conf.read_text(), expected)
            self.assertEqual(conf.stat().st_mtime_ns, before)
            self.assertFalse(list(root.glob('.vps-tune-swap.*')))

    def test_new_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.run_policy(root)
            self.assertEqual((root / '99-swap.conf').read_text(),
                             'vm.swappiness=60\nvm.page-cluster=0\n'
                             'vm.watermark_scale_factor=150\n')

    def test_dry_run_and_no_swap_leave_files_untouched(self):
        for dry, swap in ((True, '/dev/zram0'), (False, '')):
            with self.subTest(dry=dry, swap=swap), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                conf = root / '99-swap.conf'
                conf.write_text('vm.swappiness=0\n')
                self.run_policy(root, dry=dry, swap=swap)
                self.assertEqual(conf.read_text(), 'vm.swappiness=0\n')
                self.assertEqual(list(root.iterdir()), [conf])


if __name__ == '__main__':
    unittest.main()
