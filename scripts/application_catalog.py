"""Read app names only after the phone explicitly requests a picker refresh."""
import json
import re
import time
from tether_control import ForwardedControl


def parse_applications(text):
    value = json.loads(text)
    if not isinstance(value, list) or len(value) > 1000:
        raise RuntimeError('Invalid application catalog')
    apps, seen = [], set()
    for item in value:
        if not isinstance(item, dict):
            raise RuntimeError('Invalid application catalog')
        name, label = item.get('bundleName'), item.get('label')
        if not isinstance(name, str) or len(name) > 255 or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+', name):
            raise RuntimeError('Invalid application catalog')
        if not isinstance(label, str) or len(label) > 128 or re.search(r'[\x00-\x1f\x7f]', label):
            raise RuntimeError('Invalid application catalog')
        if name not in seen:
            apps.append({'bundleName': name, 'label': label})
            seen.add(name)
    return apps


def sync_applications(hdc, serial, token, forward_host):
    with ForwardedControl(hdc.run, serial, token, forward_host) as control:
        _, pending = control.request('GET', '/v1/applications/request')
        request = pending.get('request')
        if not request:
            return None  # Opening the picker alone must not enumerate applications.
        if type(request) is not int or not 0 <= int(time.time() * 1000) - request <= 45000:
            raise RuntimeError('Invalid application catalog request')
        try:
            output = hdc.shell('bm', 'dump', '-a', '-l')
        except (RuntimeError, OSError):
            control.request('POST', '/v1/applications', {'request': request, 'applications': [], 'error': 'read_failed'})
            raise RuntimeError('Application list read failed; check USB authorization') from None
        try:
            apps = parse_applications(output)
        except (ValueError, RuntimeError):
            control.request('POST', '/v1/applications', {'request': request, 'applications': [], 'error': 'unsupported'})
            raise RuntimeError('The device did not provide a supported application list') from None
        control.request('POST', '/v1/applications', {'request': request, 'applications': apps})
        return len(apps)
