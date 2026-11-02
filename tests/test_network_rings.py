"""Exercise the boot helper with driver output, without changing real NICs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


TUNE = (Path(__file__).resolve().parents[1] / "tune.sh").read_text()
HELPER = TUNE.split("RING_HELPER=$(cat <<'RING_EOF'\n", 1)[1].split("\nRING_EOF\n", 1)[0]


def rings(rx, tx, current_rx, current_tx):
    return f"""Ring parameters:
Pre-set maximums:
RX: {rx}
RX Mini: 2048
RX Jumbo: 4096
TX: {tx}
Current hardware settings:
RX: {current_rx}
RX Mini: 128
RX Jumbo: 512
TX: {current_tx}
"""


class NetworkRingsTest(unittest.TestCase):
    def run_helper(self, fixtures, args, fail_device=""):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "helper.sh").write_text(HELPER)
            for device, output in fixtures.items():
                (root / device).write_text(output)
            stub = root / "ethtool"
            stub.write_text('''#!/usr/bin/env bash
if [[ "$1" == -g ]]; then
    cat "$FIXTURES/$2" 2>/dev/null
else
    printf '%s\\n' "$*" >> "$CALLS"
    [[ "$2" != "$FAIL_DEVICE" ]]
fi
''')
            stub.chmod(0o755)
            env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"],
                       FIXTURES=tmp, CALLS=str(root / "calls"), FAIL_DEVICE=fail_device)
            result = subprocess.run(["bash", str(root / "helper.sh"), *args],
                                    env=env, text=True, capture_output=True)
            calls = (root / "calls").read_text().splitlines() if (root / "calls").exists() else []
            return result, calls

    def test_vmxnet3_uses_maxima_not_current_or_mini_jumbo(self):
        result, calls = self.run_helper({"ens192": rings(4096, 4096, 1024, 512)}, ["ens192"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["-G ens192 rx 4096 tx 4096"])

    def test_virtio_already_maximized_is_unchanged(self):
        result, calls = self.run_helper({"ens3": rings(256, 256, 256, 256)}, ["ens3"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_unsupported_interface_does_not_stop_supported_one(self):
        result, calls = self.run_helper({"ens3": rings(256, 256, 128, 128)}, ["lo", "ens3"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["-G ens3 rx 256 tx 256"])

    def test_non_numeric_tx_is_not_passed_to_ethtool(self):
        result, calls = self.run_helper({"ens3": rings(256, "n/a", 128, "n/a")}, ["ens3"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["-G ens3 rx 256"])

    def test_dry_run_does_not_set_rings(self):
        result, calls = self.run_helper({"ens192": rings(4096, 4096, 1024, 512)}, ["--dry-run", "ens192"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ethtool -G ens192 rx 4096 tx 4096", result.stdout)
        self.assertEqual(calls, [])

    def test_failure_is_reported_and_other_interfaces_are_processed(self):
        result, calls = self.run_helper({"bad": rings(256, 256, 128, 128),
                                         "good": rings(4096, 4096, 1024, 512)},
                                        ["bad", "good"], fail_device="bad")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, ["-G bad rx 256 tx 256", "-G good rx 4096 tx 4096"])


if __name__ == "__main__":
    unittest.main()
