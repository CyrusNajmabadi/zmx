"""Small IPC client shared by daemon capability integration tests."""
import os
from pathlib import Path
import socket
import struct
import subprocess


HEADER = struct.Struct('<BBHI')


def info_cwd(payload):
    # Use the fixed Info layout in src/ipc.zig. The directory length follows
    # the shell PID and command length, and its bytes follow the command buffer.
    assert len(payload) == 552, len(payload)
    assert payload[545] == 1, payload[545]
    length = struct.unpack_from('<H', payload, 14)[0]
    assert length <= 256, length
    return payload[272:272 + length]


class Session:
    """A test client for one real zmx daemon in a private socket directory."""

    def __init__(self, exe, name, optional_capabilities=None):
        self.exe = exe
        self.name = name
        self.env = dict(os.environ, SHELL='/bin/bash')
        assert self.env.get('ZMX_DIR'), 'integration tests require a private ZMX_DIR'
        self.env.pop('ZMX_SESSION', None)
        self.env.pop('ZMX_SESSION_PREFIX', None)
        self.optional_capabilities = optional_capabilities
        self.clients = []

    def run_zmx(self, *args, env=None):
        if args and args[0] in ('attach', 'run') and self.optional_capabilities is not None:
            args = (args[0], '--capabilities=' + self.optional_capabilities, *args[1:])
        result = subprocess.run([self.exe, *args], env=self.env if env is None else env,
                                capture_output=True, timeout=60)
        assert result.returncode == 0, result.stderr.decode(errors='replace')
        return result.stdout

    def close_clients(self):
        for client in self.clients:
            client.close()

    def connect(self):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.clients.append(client)
        client.settimeout(60)
        client.connect(str(Path(self.env['ZMX_DIR']) / self.name))
        return client

    def message(self, client):
        def read_exact(size):
            data = b''
            while len(data) < size:
                chunk = client.recv(size - len(data))
                assert chunk, 'daemon closed client socket'
                data += chunk
            return data

        tag, version, reserved, length = HEADER.unpack(read_exact(HEADER.size))
        assert version == 1, version
        assert reserved == 0, reserved
        assert length < 16 * 1024 * 1024, length
        return tag, read_exact(length)

    def output_until(self, client, marker):
        output = b''
        while marker not in output:
            tag, payload = self.message(client)
            if tag == 1:
                output += payload
        return output

    def attach_with_info(self):
        """Return an attached socket, its complete restore output, and session Info."""
        client = self.connect()
        size = struct.pack('<HHHH', 24, 80, 0, 0)
        # Request session Info after attaching. Its reply marks the end of the
        # restore output, including the bytes of any unfinished terminal command.
        client.sendall(HEADER.pack(7, 1, 0, len(size)) + size + HEADER.pack(6, 1, 0, 0))
        output = b''
        while True:
            tag, payload = self.message(client)
            if tag == 6:
                return client, output, payload
            if tag == 1:
                output += payload

    def attach(self):
        client, output, _ = self.attach_with_info()
        return client, output

    def query_info(self):
        client = self.connect()
        try:
            client.sendall(HEADER.pack(6, 1, 0, 0))
            while True:
                tag, payload = self.message(client)
                if tag == 6:
                    return payload
        finally:
            client.close()

    def send_output(self, output):
        client = self.connect()
        try:
            # Query on the same connection so the reply proves these exact
            # bytes were processed, even if they end inside an escape sequence.
            client.sendall(HEADER.pack(1, 1, 0, len(output)) + output + HEADER.pack(6, 1, 0, 0))
            while True:
                tag, payload = self.message(client)
                if tag == 6:
                    return payload
        finally:
            client.close()
