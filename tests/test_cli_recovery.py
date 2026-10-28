"""Regression tests for secret redaction and preserving VPN during host recovery."""
import importlib.util
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('tether_cli_recovery', SCRIPTS / 'harmony-tether.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


class RecoveryTests(unittest.TestCase):
    def test_pairing_timeout_never_exposes_token_or_command(self):
        args = SimpleNamespace(hdc='hdc', hdc_server=None, serial='serial',
                               bundle='com.linloir.hrevtether', device_port=41417)
        hdc = cli.Hdc(args)
        token = 'ab' * 32

        def timed_out(command, **_kwargs):
            raise subprocess.TimeoutExpired(command, 20)

        with mock.patch.object(cli.subprocess, 'run', side_effect=timed_out):
            with self.assertRaises(RuntimeError) as error:
                hdc.control('pair', token)
        self.assertNotIn(token, str(error.exception))
        self.assertNotIn('controlToken', str(error.exception))

    def exercise_run_exit(self, cause, adopted=False):
        actions, handlers = [], {}

        class Hdc:
            def __init__(self, args):
                self.args = args

            def connected(self, serial):
                return True

            def shell(self, *command):
                return 'com.linloir.hrevtether'

            def reverse(self, serial, port):
                actions.append('reverse')
                return True

            def vpn_present(self):
                return adopted

            def control(self, command, token):
                actions.append(command)
                return 'start ability successfully'

            def remove_reverse(self, serial, port):
                actions.append('remove_owned_reverse')

            def run(self, *command):
                raise AssertionError('Unexpected real HDC command')

        class Relay:
            dead = False
            returncode = 1

            def poll(self):
                return 1 if self.dead else None

            def terminate(self):
                self.dead = True
                actions.append('terminate_owned_relay')

            def wait(self, **_kwargs):
                return 0

        class Control:
            def __init__(self, *_args):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                pass

            def request(self, method, path, body):
                actions.append(path)
                return 202, {'request_id': body['request_id']}

        relay = Relay()

        def sleep(seconds):
            if seconds == 2:
                if cause == 'crash':
                    relay.dead = True
                else:
                    handlers[cause](cause, None)

        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'relay'
            executable.touch()
            arguments = ['harmony-tether.py', 'run', '--serial', 'serial',
                         '--relay', str(executable), '--state-dir', directory]
            connection = mock.MagicMock()
            connection.__enter__.return_value.recv.return_value = bytes.fromhex('a5200000')
            with mock.patch.object(sys, 'argv', arguments), \
                    mock.patch.object(cli, 'Hdc', Hdc), \
                    mock.patch.object(cli, 'ForwardedControl', Control), \
                    mock.patch.object(cli, 'sync_applications', return_value=None), \
                    mock.patch.object(cli, 'emit'), \
                    mock.patch.object(cli.subprocess, 'Popen', return_value=relay), \
                    mock.patch.object(cli.socket, 'create_connection', return_value=connection), \
                    mock.patch.object(cli.time, 'sleep', side_effect=sleep), \
                    mock.patch.object(cli.signal, 'signal', side_effect=lambda key, value: handlers.update({key: value})):
                if cause == 'crash':
                    with self.assertRaisesRegex(RuntimeError, 'Relay exited'):
                        cli.main()
                else:
                    cli.main()
        if adopted:
            self.assertNotIn('start', actions)
        else:
            self.assertIn('start', actions)
        self.assertIn('remove_owned_reverse', actions)
        return actions

    def test_relay_crash_preserves_established_phone_vpn(self):
        self.assertNotIn('/v1/stop', self.exercise_run_exit('crash'))

    def test_supervisor_sigterm_preserves_established_phone_vpn(self):
        self.assertNotIn('/v1/stop', self.exercise_run_exit(signal.SIGTERM))

    def test_explicit_ctrl_c_stops_only_the_vpn_started_by_this_run(self):
        self.assertIn('/v1/stop', self.exercise_run_exit(signal.SIGINT))

    def test_ctrl_c_preserves_an_adopted_vpn(self):
        self.assertNotIn('/v1/stop', self.exercise_run_exit(signal.SIGINT, adopted=True))


if __name__ == '__main__':
    unittest.main()
