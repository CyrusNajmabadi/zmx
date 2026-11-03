"""OSC 7 output assertions shared by directory and combined capability tests."""
import re


DIRECTORY = re.compile(rb'\x1b\]7;([^\x07\x1b]*)(?:\x07|\x1b\\)')
URI = b'file://localhost/tmp/zmx%20capability%20directory'
DIRECTORY_MESSAGE = b'\x1b]7;' + URI + b'\x1b\\'


def expect_directory(output, expected):
    actual = DIRECTORY.findall(output)
    assert actual == expected, (actual, expected)
    assert b'\x00' not in output, repr(output)
