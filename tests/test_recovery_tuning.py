"""Check persistence and driver-specific RX changes without touching the host."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'tune.sh').read_text()
SWAP = SOURCE.split("<<'SWAP_PY'\n", 1)[1].split('\nSWAP_PY', 1)[0]
RINGS = SOURCE.split("<<'RINGS_SH'\n", 1)[1].split('\nRINGS_SH', 1)[0]


class RecoveryTests(unittest.TestCase):
    def test_swap_updates_whitespace_keys_and_preserves_tuned_sections(self):
        with tempfile.TemporaryDirectory() as d:
            swap, tuned = Path(d)/'swap', Path(d)/'tuned'
            swap.write_text('# existing\n vm.swappiness =0\nvm.watermark_scale_factor=150\n')
            tuned.write_text('[main]\nsummary=test\n[sysctl]\nvm.swappiness=100\n[other]\nx=1\n')
            args = ['python3', '-c', SWAP, str(swap), str(tuned), '60', '0']
            subprocess.run(args, check=True)
            self.assertIn('vm.swappiness=60\n', swap.read_text())
            self.assertIn('vm.page-cluster=0\n', swap.read_text())
            self.assertIn('vm.watermark_scale_factor=150', swap.read_text())
            self.assertIn('[sysctl]\nvm.swappiness=60\nvm.page-cluster=0\n[other]\nx=1', tuned.read_text())
            before = {p.name:p.read_bytes() for p in Path(d).iterdir()}
            subprocess.run(args, check=True)
            self.assertEqual(before, {p.name:p.read_bytes() for p in Path(d).iterdir()})

    def test_missing_swap_and_missing_tuned_sysctl_section(self):
        with tempfile.TemporaryDirectory() as d:
            swap, tuned = Path(d)/'swap', Path(d)/'tuned'
            subprocess.run(['python3', '-c', SWAP, str(swap), str(tuned), '60', '0'], check=True)
            self.assertFalse(tuned.exists())
            self.assertIn('vm.swappiness=60', swap.read_text())
            tuned.write_text('[main]\nsummary=test\n')
            subprocess.run(['python3', '-c', SWAP, str(swap), str(tuned), '60', '0'], check=True)
            self.assertIn('[sysctl]\n\nvm.swappiness=60\nvm.page-cluster=0', tuned.read_text())

    def test_rx_maximum_is_per_driver_and_does_not_change_tx(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root/'ethtool').write_text('''#!/bin/bash
if [[ "$1" == -G ]]; then echo "$*" >> "$CALLS"; exit 0; fi
case "$2" in
unsupported) exit 1;;
ens3) maximum=256; current=256;;
ens192) maximum=4096; current=1024;;
*) exit 1;;
esac
printf 'Pre-set maximums:\\nRX: %s\\nTX: 4096\\nCurrent hardware settings:\\nRX: %s\\nTX: 1024\\n' "$maximum" "$current"
''')
            (root/'ethtool').chmod(0o755)
            env = dict(os.environ, PATH=d+':'+os.environ['PATH'], CALLS=str(root/'calls'))
            subprocess.run(['bash', '-c', RINGS, 'rings', 'unsupported', 'ens3', 'ens192'], env=env, check=True, capture_output=True)
            self.assertEqual((root/'calls').read_text(), '-G ens192 rx 4096\n')


if __name__ == '__main__':
    unittest.main()
