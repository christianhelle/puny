#!/usr/bin/env python3
"""End-to-end checks for typing while a response streams.

Regression tests run puny without a terminal, where the cancel monitor never
starts, so this drives the real binary through a pseudo-terminal.

Usage: enqueue_pty.py <path to puny>
"""

import os
import pty
import re
import select
import shutil
import signal
import sys
import tempfile
import time

ANSI = re.compile(r"\x1b(\[[0-9;?]*[ -/]*[@-~]|[@-Z\\^_])")
TIMEOUT_SECONDS = 30
SHORT_STREAM = b"slow\r"
# Takes far longer than a test should, so only for turns the test cancels.
LONG_STREAM = b"slow long story\r"


class Puny:
    def __init__(self, binary, home):
        self.output = ""
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["HOME"] = home
            os.environ["XDG_CONFIG_HOME"] = os.path.join(home, ".config")
            os.environ["TERM"] = "xterm-256color"
            os.chdir(home)
            os.execv(binary, [binary, "--mock", "--model", "mock-model"])

    def pump(self, seconds):
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                return
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            self.output += ANSI.sub("", data.decode("utf-8", "replace"))

    def wait_for(self, text, start=0):
        deadline = time.monotonic() + TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            index = self.output.find(text, start)
            if index >= 0:
                return index
            self.pump(0.05)
        raise AssertionError(f"timed out waiting for {text!r}; output was:\n{self.output}")

    def send(self, data):
        os.write(self.fd, data)

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(self.pid, 0)
        os.close(self.fd)


def start_streaming(puny, prompt):
    """Submits a slow prompt and returns once its response is streaming."""
    puny.wait_for(">")
    puny.pump(0.3)
    mark = len(puny.output)
    puny.send(prompt)
    puny.wait_for("Thinking", mark)
    return mark


def line_typed_while_streaming_is_delivered(puny):
    mark = start_streaming(puny, SHORT_STREAM)
    puny.send(b"say fast\r")

    queued = puny.wait_for("Queued: say fast", mark)
    # The mock echoes the message it is answering.
    puny.wait_for("say fast", queued + len("Queued: say fast"))


def cancel_holds_typed_text_for_the_prompt(puny):
    mark = start_streaming(puny, LONG_STREAM)
    puny.pump(0.5)
    puny.send(b"draft one\r")
    puny.send(b"partial")
    puny.pump(0.3)
    puny.send(b"\x1b")
    puny.pump(0.05)
    puny.send(b"\x1b")

    puny.wait_for("draft one partial", mark)
    assert "Queued:" not in puny.output[mark:], puny.output[mark:]


def run_case(binary, case):
    home = tempfile.mkdtemp(prefix="puny-pty-")
    # An existing config keeps the first-launch setup wizard away.
    config_dir = os.path.join(home, ".config", "puny")
    os.makedirs(config_dir)
    with open(os.path.join(config_dir, "config.json"), "w", encoding="utf-8") as config:
        config.write('{"provider":"lmstudio"}\n')
    puny = Puny(binary, home)
    try:
        case(puny)
        print(f"ok   {case.__name__}")
        return True
    except AssertionError as error:
        print(f"FAIL {case.__name__}: {error}")
        return False
    finally:
        puny.close()
        shutil.rmtree(home, ignore_errors=True)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    binary = os.path.abspath(sys.argv[1])
    cases = [line_typed_while_streaming_is_delivered, cancel_holds_typed_text_for_the_prompt]
    results = [run_case(binary, case) for case in cases]
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
