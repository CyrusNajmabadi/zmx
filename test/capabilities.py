"""Real daemon checks for capability selection and two capabilities working together."""
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import termios
import time
import re
import subprocess
import sys

from capability_helpers import Session, info_cwd
from working_directory.output import DIRECTORY_MESSAGE, URI, expect_directory


PROGRAM_STATUS = re.compile(rb'\x1b\]7501;([^\x07\x1b]*)(?:\x07|\x1b\\)')


def required_capabilities(session):
    session.run_zmx('run', session.name, '-d', 'cat')
    monitor, _ = session.attach()
    status = b'\x1b]7501;state=working\x07'
    info = session.send_output(DIRECTORY_MESSAGE + status + b'live-only')
    live = session.output_until(monitor, b'live-only')
    expect_directory(live, [URI])
    assert PROGRAM_STATUS.findall(live) == [b'state=working'], repr(live)
    assert info_cwd(info) == URI, info_cwd(info)
    _, snapshot = session.attach()
    expect_directory(snapshot, [URI])
    assert PROGRAM_STATUS.findall(snapshot) == [], repr(snapshot)


def compiled_capabilities(session):
    session.name = 'libzmx-capabilities'
    fixture = str(Path(session.exe).with_name('test-capability-session'))

    def create(*args):
        # No library call may inherit capability selection from the environment.
        result = subprocess.run([fixture, *args], env=dict(session.env, ZMX_CAPABILITIES='not-registered'),
                                capture_output=True, timeout=60)
        assert result.returncode == 0, result.stderr.decode(errors='replace')

    create()
    status = b'\x1b]7501;state=working\x07'
    unknown = b'\x1b]7777;not-enabled\x07'
    info = session.send_output(DIRECTORY_MESSAGE + status + unknown + b'compiled-ready')
    assert info_cwd(info) == URI, info_cwd(info)
    monitor, snapshot = session.attach()
    expect_directory(snapshot, [URI])
    assert PROGRAM_STATUS.findall(snapshot) == [b'state=clear', b'state=working'], repr(snapshot)
    assert snapshot.index(b'\x1b]7;') < snapshot.index(b'\x1b]7501;'), repr(snapshot)
    assert unknown not in snapshot, repr(snapshot)

    # Each capability restores its complete messages before the unfinished
    # OSC 7501 message, whose remaining bytes still come from live output.
    pending = b'\x1b]7501;state=blocked:id=worker:kind=permission'
    session.send_output(pending)
    target, snapshot = session.attach()
    expect_directory(snapshot, [URI])
    assert snapshot.endswith(pending), repr(snapshot)
    session.send_output(b'\x07compiled-finished')
    restored = snapshot + session.output_until(target, b'compiled-finished')
    assert PROGRAM_STATUS.findall(restored) == [
        b'state=clear', b'state=working', b'state=blocked:id=worker:kind=permission'
    ], repr(restored)
    live = session.output_until(monitor, b'compiled-finished')
    expect_directory(live, [])
    assert PROGRAM_STATUS.findall(live) == [b'state=blocked:id=worker:kind=permission'], repr(live)

    # A later client requests no optional capabilities. The already-running daemon
    # must keep saving and restoring Program Status using its original selection.
    create('empty')
    session.send_output(b'\x1b]7501;state=done:id=later\x07')
    _, snapshot = session.attach()
    expect_directory(snapshot, [URI])
    assert PROGRAM_STATUS.findall(snapshot) == [
        b'state=clear', b'state=working', b'state=blocked:id=worker:kind=permission',
        b'state=done:id=later'
    ], repr(snapshot)


def library_required_only(session):
    session.name = 'libzmx-capabilities'
    fixture = str(Path(session.exe).with_name('test-capability-session'))
    # The obsolete setting must neither enable a valid name nor reject an invalid one.
    for value in ('osc7501', 'missing'):
        result = subprocess.run([fixture, 'default'], env=dict(session.env, ZMX_CAPABILITIES=value),
                                capture_output=True, timeout=60)
        assert result.returncode == 0, result.stderr.decode(errors='replace')
        session.send_output(DIRECTORY_MESSAGE + b'\x1b]7501;state=working\x07')
        _, snapshot = session.attach()
        expect_directory(snapshot, [URI])
        assert PROGRAM_STATUS.findall(snapshot) == [], repr(snapshot)
        session.close_clients()
        session.run_zmx('kill', '--force', session.name)


def cli_selection(session, form):
    session.name = 'cli-' + form
    # A real CLI daemon must receive only the optional definitions. Passing a full
    # registry list would duplicate OSC 7 and prevent creation entirely.
    option = ['--capabilities', 'osc7501'] if form == 'separate' else ['--capabilities=osc7501']
    session.run_zmx('run', *option, session.name, '-d', 'cat')
    session.send_output(DIRECTORY_MESSAGE + b'\x1b]7501;state=working:id=cli\x07')
    _, snapshot = session.attach()
    expect_directory(snapshot, [URI])
    assert PROGRAM_STATUS.findall(snapshot) == [b'state=clear', b'state=working:id=cli'], repr(snapshot)

    # Later CLI calls cannot remove the running daemon's original selection.
    session.run_zmx('run', '--capabilities=', session.name, '-d', 'true')
    session.send_output(b'\x1b]7501;state=done:id=later\x07')
    _, snapshot = session.attach()
    assert b'state=done:id=later' in PROGRAM_STATUS.findall(snapshot), repr(snapshot)


def invalid_selection_does_not_read_stdin(session):
    process = subprocess.Popen([
        session.exe, 'run', '--capabilities=missing', session.name,
    ], env=session.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        # Leave stdin open. Reading commands before rejecting the option would
        # block here, even though ordinary BATS input is already at EOF.
        assert process.wait(timeout=60) != 0
        assert b'unknown capability' in process.stderr.read()
        assert not (Path(session.env['ZMX_DIR']) / session.name).exists()
    finally:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=60)
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()


def cli_attach(session):
    # Use a private pseudo-terminal, without a window or an interactive shell, so
    # this exercises the actual CLI attach path as well as the parser.
    master, slave = pty.openpty()
    process = None
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        process = subprocess.Popen([
            session.exe, 'attach', '--labels=source=capability-test',
            '--capabilities', 'osc7501', session.name, 'cat',
        ], env=session.env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        os.close(slave)
        slave = None
        deadline = time.monotonic() + 60
        socket_path = Path(session.env['ZMX_DIR']) / session.name
        while not socket_path.exists():
            assert process.poll() is None, process.stderr.read()
            assert time.monotonic() < deadline, 'CLI attach did not create its daemon'
            time.sleep(0.01)

        # Wait for bytes forwarded through the CLI before checking its saved state.
        # A socket alone would not prove the attach client actually connected.
        session.send_output(DIRECTORY_MESSAGE + b'\x1b]7501;state=blocked:id=cli\x07attach-ready')
        output = b''
        while b'attach-ready' not in output:
            assert time.monotonic() < deadline, repr(output)
            ready, _, _ = select.select([master], [], [], 1)
            if ready:
                output += os.read(master, 65536)

        _, snapshot = session.attach()
        expect_directory(snapshot, [URI])
        assert PROGRAM_STATUS.findall(snapshot) == [b'state=clear', b'state=blocked:id=cli'], repr(snapshot)
        labels = session.run_zmx('get', session.name)
        assert b'source=capability-test' in labels, labels
        session.run_zmx('kill', '--force', session.name)
        assert process.wait(timeout=60) == 0, process.stderr.read()
    finally:
        if process is not None:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=60)
            process.stderr.close()
        if slave is not None:
            os.close(slave)
        os.close(master)


if __name__ == '__main__':
    if not __debug__:
        raise RuntimeError('capability checks require Python assertions')
    scenario, exe = sys.argv[1:]
    session = Session(exe, 'capability-test')
    scenarios = {
        'required': required_capabilities,
        'compiled': compiled_capabilities,
        'library-default': library_required_only,
        'cli-separate': lambda s: cli_selection(s, 'separate'),
        'cli-equals': lambda s: cli_selection(s, 'equals'),
        'cli-attach': cli_attach,
        'invalid-stdin': invalid_selection_does_not_read_stdin,
    }
    try:
        if scenario == 'required':
            session.env['ZMX_CAPABILITIES'] = 'osc7501'
        scenarios[scenario](session)
    finally:
        session.close_clients()
