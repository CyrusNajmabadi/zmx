#!/usr/bin/env bats

load test_helper

@test "print-env returns missing-variable errors and preserves tracked values" {
  python3 -E - "$ZMX" 3>&- <<'PYTEST'
import fcntl
import os
import pathlib
import pty
import resource
import struct
import subprocess
import sys
import termios
import time

zmx = sys.argv[1]
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
name = 'test-print-env'
env = dict(os.environ, SHELL='/bin/sh', ZMX_TRACK_ENV='ZMX_TEST_VALUE,ZMX_TEST_EMPTY,ZMX_TEST_UNSET',
           ZMX_TEST_VALUE='value with spaces=and equals', ZMX_TEST_EMPTY='')
for key in ('ZMX_SESSION', 'ZMX_SESSION_PREFIX', 'ZMX_TEST_UNSET'):
    env.pop(key, None)
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
process = subprocess.Popen([zmx, 'attach', name, '/bin/sh', '-c', 'exec sleep 300'],
                           stdin=slave, stdout=slave, stderr=subprocess.PIPE, env=env)

def query(*args):
    return subprocess.run([zmx, 'print-env', name, *args], env=env,
                          capture_output=True, timeout=60)

try:
    expected = b'ZMX_TEST_VALUE=value with spaces=and equals\nZMX_TEST_EMPTY=\n-ZMX_TEST_UNSET\n'
    deadline = time.monotonic() + 60
    while True:
        result = query()
        if result.returncode == 0 and result.stdout == expected:
            break
        assert process.poll() is None, process.returncode
        assert time.monotonic() < deadline, result
        time.sleep(0.05)

    for key in ('ZMX_TEST_UNSET', 'ZMX_TEST_MISSING', 'ZMX_TEST_VAL'):
        result = query(key)
        assert result.returncode == 1, (key, result)
        assert result.stdout == b'', (key, result)
        assert result.stderr == b'error: environment variable not found\n', (key, result)

    for key, value in (('ZMX_TEST_VALUE', b'value with spaces=and equals\n'),
                       ('ZMX_TEST_EMPTY', b'\n')):
        result = query(key)
        assert result.returncode == 0 and result.stdout == value and result.stderr == b'', (key, result)

    result = query()
    assert result.returncode == 0 and result.stdout == expected and result.stderr == b'', result
    # Debug allocator errors go to zmx.log even when the command exits normally.
    log = pathlib.Path(env['ZMX_DIR']) / 'logs' / 'zmx.log'
    assert 'Double free detected' not in log.read_text(), log.read_text()
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=30)
    process.stderr.close()
    os.close(master)
    os.close(slave)
PYTEST
}
