"""scope_proto.py - binary packet protocol of the scope dongle (reference code)

Used by the cocotb testbench and by scope_cli.py; mirror it in the PC app.
Full description: docs/protocol.md

Frame (both directions):
    0xA5 | TYPE | LEN lo | LEN hi | PAYLOAD (LEN bytes) | CRC lo | CRC hi
    CRC = CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) over TYPE, LEN, PAYLOAD
Responses: TYPE | 0x80, or 0xFF = NAK with payload (code, request type).
All multi-byte fields are little-endian.
"""
import struct

SYNC = 0xA5
MAX_REQ_PAYLOAD = 64

PING, GET_INFO, SET_CONFIG, GET_CONFIG, ACQUIRE = 0x01, 0x02, 0x03, 0x04, 0x05
GET_REV, SET_REV, TEXT = 0x07, 0x08, 0x09
NAK = 0xFF
ABORT_BYTE = 0x18          # any byte aborts a waiting ACQUIRE; CAN by convention

NAK_CODES = {1: "CRC error", 2: "bad length", 3: "unknown type", 4: "bad argument"}
TRIG_MODES = {"auto": 0, "normal": 1, "immediate": 2}
ACQ_STATUS = {0: "ok", 2: "aborted"}


def crc16(data, crc=0xFFFF):
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc


def frame(ftype, payload=b""):
    body = bytes([ftype]) + struct.pack("<H", len(payload)) + bytes(payload)
    return bytes([SYNC]) + body + struct.pack("<H", crc16(body))


class FrameError(Exception):
    pass


class Parser:
    """Incremental receiver: feed() bytes, get complete (type, payload) frames."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            i = self.buf.find(bytes([SYNC]))
            if i < 0:
                self.buf.clear()
                return out
            del self.buf[:i]
            if len(self.buf) < 4:
                return out
            n = self.buf[2] | (self.buf[3] << 8)
            if len(self.buf) < 6 + n:
                return out
            body = bytes(self.buf[1:4 + n])
            rx_crc = self.buf[4 + n] | (self.buf[5 + n] << 8)
            del self.buf[:6 + n]
            if crc16(body) != rx_crc:
                raise FrameError("CRC mismatch")
            out.append((body[0], body[3:]))


# ---- payloads ----------------------------------------------------------------------
def pack_config(sr, ss=1024, pt=0, tm="auto", te="rising", tl=128, th=4,
                ph=None, pd=0, tp=0):
    """SET_CONFIG payload, 16 bytes. ph=None -> automatic capture phase."""
    tm = TRIG_MODES[tm] if isinstance(tm, str) else tm
    te = {"rising": 0, "falling": 1}[te] if isinstance(te, str) else te
    return struct.pack("<IHHBBBBBBBB", int(sr), ss, pt, tm, te, tl, th,
                       0xFF if ph is None else ph, pd, tp, 0)


def unpack_config(p):
    f = struct.unpack("<IIHHBBBBBBBB", p)
    keys = ("sr", "adc_hz", "ss", "pt", "tm", "te", "tl", "th", "ph", "pd", "tp", "ck")
    return dict(zip(keys, f))


def unpack_info(p):
    proto, fw_maj, fw_min, bits, max_sr, max_ss = struct.unpack("<BBBBIH", p[:10])
    return dict(proto=proto, fw=f"{fw_maj}.{fw_min}", adc_bits=bits,
                max_sr=max_sr, max_samples=max_ss, rev=p[10:18].decode("ascii", "replace"))


def unpack_acquire(p):
    status, trig, seq, sr, pt, n = struct.unpack("<BBHIHH", p[:12])
    return dict(status=status, triggered=trig, seq=seq, sr=sr, pt=pt, n=n,
                samples=bytes(p[12:12 + n]))


def unpack_nak(p):
    return dict(code=p[0], request=p[1], reason=NAK_CODES.get(p[0], "?"))
