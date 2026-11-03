"""Minimal viewer for the core's stream socket (platform/ipc/stream*.odin).

Frame: [kind u8][channel u32 LE][len u32 LE][payload]. Only what the stress
check needs: HELLO, CREATE, ATTACH, DATA with CREDIT.
"""
import collections
import socket
import struct
import time

HDR = struct.Struct("<BII")
DATA, CREDIT, CLOSE = 0, 1, 2
HELLO, CREATE, ATTACH = 10, 61, 63
V_INPUT = 70
ATTACHED, FAIL = 82, 84
ROLE_VIEWER = 3
PAINT = b"\x18\x1b[!p"  # every first paint / repaint starts with CAN + soft reset


def _str(b):
    return struct.pack("<I", len(b)) + b


def _size(cols, rows):
    return struct.pack("<HHHH", cols, rows, cols * 10, rows * 20)


class Link:
    def __init__(self, sock_path, timeout=5.0):
        deadline = time.time() + timeout
        while True:
            self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                self.s.connect(sock_path)
                break
            except OSError:
                self.s.close()
                if time.time() > deadline:
                    raise
                time.sleep(0.05)
        self.buf = bytearray()
        self.held = collections.deque()  # frames that arrived while waiting for an answer
        self.token = 0
        self.send(HELLO, 0, struct.pack("<IBQ", 1, ROLE_VIEWER, 0) + _str(b"stress"))
        f = self.next(5)
        if f is None or f[0] != HELLO:
            raise RuntimeError("no HELLO from the core")

    def close(self):
        self.s.close()

    def send(self, kind, channel, payload=b""):
        self.s.sendall(HDR.pack(kind, channel, len(payload)) + payload)

    def next(self, timeout=None):
        """The next frame, None on timeout; EOFError when the core is gone."""
        return self.held.popleft() if self.held else self._recv_frame(timeout)

    def _recv_frame(self, timeout):
        """The next frame off the socket (not the held ones)."""
        self.s.settimeout(timeout)
        while True:
            if len(self.buf) >= HDR.size:
                kind, channel, n = HDR.unpack_from(self.buf)
                if len(self.buf) >= HDR.size + n:
                    payload = bytes(self.buf[HDR.size:HDR.size + n])
                    del self.buf[:HDR.size + n]
                    return kind, channel, payload
            try:
                chunk = self.s.recv(1 << 20)
            except socket.timeout:
                return None
            except OSError:
                chunk = b""
            if not chunk:
                raise EOFError("core closed the link")
            self.buf += chunk

    def _attached(self, token):
        """Waits for the answer to `token`; other frames stay queued for next()."""
        early = []
        try:
            while True:
                f = self._recv_frame(5)
                if f is None:
                    raise RuntimeError("no answer to CREATE/ATTACH")
                kind, _, p = f
                if kind == FAIL and struct.unpack_from("<I", p)[0] == token:
                    raise RuntimeError("core refused: %r" % p[5:])
                if kind == ATTACHED and struct.unpack_from("<I", p)[0] == token:
                    _, sid, channel = struct.unpack("<III", p)
                    return sid, channel
                early.append(f)
        finally:
            self.held.extend(early)

    def create(self, argv, cols=80, rows=24):
        self.token += 1
        spec = struct.pack("<I", len(argv)) + b"".join(_str(a.encode()) for a in argv)
        spec += struct.pack("<I", 0) + _str(b"/tmp") + _size(cols, rows)
        self.send(CREATE, 0, struct.pack("<I", self.token) + spec)
        return self._attached(self.token)

    def attach(self, sid, cols=80, rows=24):
        self.token += 1
        req = struct.pack("<II", self.token, sid) + _size(cols, rows) + struct.pack("<IB", 0, 0)
        self.send(ATTACH, 0, req)
        return self._attached(self.token)[1]


class Stream:
    """Counts what one attach channel delivered and grants credit for it."""

    def __init__(self, channel, marker=b""):
        self.channel, self.marker = channel, marker
        self.bytes = self.paints = 0
        self.done = self.closed = False
        self._tail = b""

    def feed(self, link, kind, channel, payload):
        if channel != self.channel:
            return False
        if kind == CLOSE:
            self.closed = True
        if kind != DATA:
            return True
        self.bytes += len(payload)
        seen = self._tail + payload
        self.paints += seen.count(PAINT) - self._tail.count(PAINT)
        if self.marker and self.marker in seen:
            self.done = True
        self._tail = seen[-32:]
        link.send(CREDIT, channel, struct.pack("<I", len(payload)))
        return True


def pump(link, streams, seconds, until_done=False):
    """Serve every stream for `seconds` (or until all are done)."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        if until_done and all(s.done for s in streams):
            return True
        f = link.next(0.2)
        if f is not None:
            for s in streams:
                if s.feed(link, *f):
                    break
    return all(s.done for s in streams)
