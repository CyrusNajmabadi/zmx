"""OSC 7 directory metadata and reconnect checks against a real daemon."""
import re
import socket
import sys

from capability_helpers import Session, info_cwd
from working_directory.output import DIRECTORY_MESSAGE, URI, expect_directory


PROGRAM_STATUS = re.compile(rb'\x1b\]7501;([^\x07\x1b]*)(?:\x07|\x1b\\)')


def default_directory_capability(session):
    session.run_zmx('run', session.name, '-d', 'cat')
    info = session.send_output(DIRECTORY_MESSAGE + b'directory-ready')
    assert info_cwd(info) == URI, info_cwd(info)
    first, snapshot = session.attach()
    expect_directory(snapshot, [URI])
    assert PROGRAM_STATUS.findall(snapshot) == [], repr(snapshot)
    _, snapshot = session.attach()
    expect_directory(snapshot, [URI])

    # A new directory remains incomplete until its terminator arrives.
    # Reconnecting must preserve both the last complete value and its prefix.
    pending_uri = b'file://localhost/tmp/another%20directory'
    pending = b'\x1b]7;' + pending_uri
    info = session.send_output(pending)
    assert info_cwd(info) == URI, info_cwd(info)
    target, snapshot = session.attach()
    expect_directory(snapshot, [URI])
    assert snapshot.endswith(pending), repr(snapshot)
    info = session.send_output(b'\x07directory-finished')
    assert info_cwd(info) == pending_uri, info_cwd(info)
    restored = snapshot + session.output_until(target, b'directory-finished')
    expect_directory(restored, [URI, pending_uri])
    live = session.output_until(first, b'directory-finished')
    expect_directory(live, [pending_uri])


def normalized_directory_metadata(session):
    session.run_zmx('run', session.name, '-d', 'cat')
    path = b'/tmp/zmx capability directory'
    info = session.send_output(b'\x1b]7;' + path + b'\x07')
    expected = b'file://' + socket.gethostname().encode() + b'/tmp/zmx%20capability%20directory'
    assert info_cwd(info) == expected, (info_cwd(info), expected)

    # Remote directory metadata must keep the remote host visible.
    remote = b'file://another-host/home/agent%20workspace'
    info = session.send_output(b'\x1b]7;' + remote + b'\x07')
    assert info_cwd(info) == remote, info_cwd(info)
    _, snapshot = session.attach()
    expect_directory(snapshot, [remote])


if __name__ == '__main__':
    if not __debug__:
        raise RuntimeError('directory checks require Python assertions')
    scenario, exe = sys.argv[1:]
    session = Session(exe, 'directory-test')
    scenarios = {
        'default-directory': default_directory_capability,
        'normalized-directory': normalized_directory_metadata,
    }
    try:
        scenarios[scenario](session)
    finally:
        session.close_clients()
