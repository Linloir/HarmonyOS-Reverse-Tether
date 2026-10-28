"""Exercise the real local HTTP boundary and exact HDC forward ownership."""
import importlib.util
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location('tether_control', Path(__file__).resolve().parents[1] / 'scripts/tether_control.py')
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


class ControlTests(unittest.TestCase):
    def test_token_is_stable_private_and_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'device.token'
            token = control.ensure_token(path)
            self.assertEqual(len(token), 64)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(control.ensure_token(path), token)
            link = Path(directory) / 'link'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                control.read_token(link)
            path.chmod(0o644)
            with self.assertRaises(control.ControlError):
                control.read_token(path)

    def test_forward_cleanup_preserves_a_reassigned_port(self):
        rows = []
        removed = []

        def run(*args):
            if args == ('fport', 'ls'):
                return '\n'.join(' '.join(row) for row in rows)
            if args[1] == 'rm':
                removed.append(args)
                return ''
            rows.append(['serial', args[1], args[2], '[Forward]'])
            return 'Forwardport result:OK'

        with control.ForwardedControl(run, 'serial') as endpoint:
            self.assertEqual(rows[0][2], 'tcp:41420')
            rows[0][0] = 'another-device'
        self.assertEqual(removed, [])
        rows.clear()
        with control.ForwardedControl(run, 'serial'):
            pass
        self.assertEqual(len(removed), 1)

    def test_authenticated_http_is_bounded_and_does_not_follow_redirects(self):
        received = []
        token = 'ab' * 32

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                received.append((self.path, self.headers.get('Authorization')))
                body = json.dumps({'protocol_version': 2, 'state': 'connected'}).encode()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                received.append((self.path, self.headers.get('Authorization')))
                size = int(self.headers.get('Content-Length', '0'))
                self.rfile.read(size)
                if self.path == '/v1/stop':
                    self.send_response(401)
                    self.end_headers()
                    self.wfile.write(b'{"error":"unauthorized"}')
                else:
                    self.send_response(302)
                    self.send_header('Location', 'http://example.invalid/')
                    self.end_headers()
                    self.wfile.write(b'{"error":"redirect"}')

            def log_message(self, *args):
                pass

        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            endpoint = control.ForwardedControl(lambda *a: '', 'serial', token)
            endpoint.port = server.server_port
            code, reply = endpoint.request('GET', '/v1/status')
            self.assertEqual((code, reply['protocol_version']), (200, 2))
            with self.assertRaises(control.ControlError) as error:
                endpoint.request('POST', '/v1/stop', {'request_id': 'test'})
            self.assertEqual(error.exception.code, 'pairing_required')
            self.assertNotIn(token, str(error.exception))
            with self.assertRaises(control.ControlError) as redirect:
                endpoint.request('POST', '/v1/probe', {'request_id': 'test'})
            self.assertEqual(redirect.exception.status, 302)
            self.assertTrue(all(auth == 'Bearer ' + token for _, auth in received))
            self.assertEqual(len(received), 3)
            endpoint.token = None
            with self.assertRaises(control.ControlError):
                endpoint.request('POST', '/v1/probe', {})
            self.assertEqual(len(received), 3)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2)


if __name__ == '__main__':
    unittest.main()
