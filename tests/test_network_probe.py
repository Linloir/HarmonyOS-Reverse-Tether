"""Keep missing, inconsistent and failed measurements distinct from total loss."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('network_probe', Path(__file__).resolve().parents[1] / 'scripts/network-probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ProbeMeasurementTests(unittest.TestCase):
    def test_complete_loss_has_explicit_null_rtt(self):
        value = dict(protocol='stun_binding_v1', sent=5, received=0, packet_loss_percent=100, median_rtt_ms=None)
        probe.validate_value(value)
        del value['median_rtt_ms']
        with self.assertRaises(RuntimeError):
            probe.validate_value(value)

    def test_rejects_inconsistent_or_missing_core_fields(self):
        value = dict(protocol='stun_binding_v1', sent=5, received=4, packet_loss_percent=20, median_rtt_ms=8)
        probe.validate_value(value)
        for key, invalid in [('sent', True), ('received', None), ('packet_loss_percent', 0),
                             ('median_rtt_ms', None), ('median_rtt_ms', float('nan')),
                             ('median_rtt_ms', -1), ('protocol', 'unknown')]:
            with self.subTest(key=key, value=invalid):
                with self.assertRaises(RuntimeError):
                    probe.validate_value(dict(value, **{key: invalid}))


if __name__ == '__main__':
    unittest.main()
