"""Control forwards must have a cleanup budget after a probe deadline expires."""
import importlib.util
from pathlib import Path
import subprocess
import unittest

spec = importlib.util.spec_from_file_location('control_recovery', Path(__file__).resolve().parents[1] / 'scripts/tether_control.py')
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


class ControlRecoveryTests(unittest.TestCase):
    def test_expired_operation_uses_separate_cleanup_budget(self):
        rows, cleaned = [], []
        expired = False

        def run(*command):
            if expired:
                raise subprocess.TimeoutExpired(command, .1)
            if command == ('fport', 'ls'):
                return '\n'.join(' '.join(row) for row in rows)
            rows.append(['serial', command[1], command[2], '[Forward]'])
            return 'Forwardport result:OK'

        def cleanup(*command):
            cleaned.append(command)
            if command == ('fport', 'ls'):
                return '\n'.join(' '.join(row) for row in rows)
            self.assertEqual(command, ('fport', 'rm', rows[0][1], rows[0][2]))
            rows.clear()
            return ''

        with control.ForwardedControl(run, 'serial', cleanup_run=cleanup):
            expired = True
        self.assertEqual(rows, [])
        self.assertEqual(len(cleaned), 2)

    def test_uncertain_forward_receipt_still_cleans_exact_owned_mapping(self):
        rows, removed = [], []

        def run(*command):
            if command == ('fport', 'ls'):
                return ''
            rows.append(['serial', command[1], command[2], '[Forward]'])
            raise subprocess.TimeoutExpired(command, 5)

        def cleanup(*command):
            if command == ('fport', 'ls'):
                return '\n'.join(' '.join(row) for row in rows)
            removed.append(command)
            rows.clear()
            return ''

        with self.assertRaises(subprocess.TimeoutExpired):
            with control.ForwardedControl(run, 'serial', cleanup_run=cleanup):
                self.fail('A missing creation receipt cannot be used for requests')
        self.assertEqual(len(removed), 1)
        self.assertEqual(rows, [])


if __name__ == '__main__':
    unittest.main()
