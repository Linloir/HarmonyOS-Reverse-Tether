"""Keep missing, inconsistent and failed measurements distinct from total loss."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('network_probe', Path(__file__).resolve().parents[1] / 'scripts/network-probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ProbeMeasurementTests(unittest.TestCase):
    def test_ipv6_stun_addresses_are_unambiguous(self):
        self.assertEqual(probe.parse_server('[2001:db8::1]:3478'), {'host': '2001:db8::1', 'port': 3478})
        self.assertEqual(probe.parse_server('stun.example.com:3478')['host'], 'stun.example.com')
        for value in ['2001:db8::1:3478', '[fe80::1%eth0]:3478', '999.1.1.1:3478', 'bad..host:3478', 'host:0']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                probe.parse_server(value)

    def test_background_probe_requires_matching_vpn_session_and_traffic(self):
        value = dict(protocol='stun_binding_v1', sent=5, received=4, packet_loss_percent=20, median_rtt_ms=8)
        reply = dict(request_id='id', path='vpn', vpn_session=123, tx_bytes_delta=120, rx_bytes_delta=60, value=value)
        probe.validate_vpn_reply(reply, 'id', 123)
        for key, invalid in [('request_id', 'other'), ('path', 'wifi'), ('vpn_session', 124),
                             ('tx_bytes_delta', 0), ('tx_bytes_delta', True), ('rx_bytes_delta', -1), ('error', 'vpn_changed')]:
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                probe.validate_vpn_reply(dict(reply, **{key: invalid}), 'id', 123)

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
