#!/usr/bin/env python3
"""scope_cli.py - talk to the scope dongle in binary packet mode (needs pyserial)

    pip install pyserial
    python host/scope_cli.py COM5 info
    python host/scope_cli.py COM5 rev
    python host/scope_cli.py COM5 setrev REV-A001
    python host/scope_cli.py COM5 acquire --sr 10e6 --ss 1024 --mode auto --csv out.csv
    python host/scope_cli.py COM5 text            # back to the text command line

The tool sends "SPC" first, so it works whether the board is in text or
packet mode. 921600 baud by default.
"""
import argparse
import sys
import time

import serial

import scope_proto as sp


class Dongle:
    def __init__(self, port, baud=921600, timeout=2.0):
        self.ser = serial.Serial(port, baud, timeout=0.05)
        self.timeout = timeout
        self.parser = sp.Parser()

    def enter_packet_mode(self):
        self.ser.reset_input_buffer()
        self.ser.write(b"SPC\n")
        time.sleep(0.05)
        self.ser.reset_input_buffer()     # discard the "OK SPC" line (or a NAK)

    def request(self, ftype, payload=b"", timeout=None):
        self.ser.write(sp.frame(ftype, payload))
        deadline = time.time() + (timeout or self.timeout)
        while time.time() < deadline:
            data = self.ser.read(4096)
            if data:
                frames = self.parser.feed(data)
                if frames:
                    rtype, rp = frames[0]
                    if rtype == sp.NAK:
                        raise RuntimeError(f"NAK: {sp.unpack_nak(rp)}")
                    return rtype, rp
        raise TimeoutError("no response")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port")
    ap.add_argument("cmd", choices=["ping", "info", "rev", "setrev", "config", "acquire", "text"])
    ap.add_argument("arg", nargs="?")
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--sr", type=float, default=10e6)
    ap.add_argument("--ss", type=int, default=1024)
    ap.add_argument("--pt", type=int, default=0)
    ap.add_argument("--mode", default="auto", choices=list(sp.TRIG_MODES))
    ap.add_argument("--edge", default="rising", choices=["rising", "falling"])
    ap.add_argument("--level", type=int, default=128)
    ap.add_argument("--hyst", type=int, default=4)
    ap.add_argument("--ph", type=int, default=None)
    ap.add_argument("--tp", type=int, default=0)
    ap.add_argument("--csv")
    a = ap.parse_args()

    d = Dongle(a.port, a.baud)
    d.enter_packet_mode()

    if a.cmd == "ping":
        t0 = time.time()
        _, p = d.request(sp.PING, b"hello")
        print(f"PING ok: {p!r} in {1e3 * (time.time() - t0):.1f} ms")
    elif a.cmd == "info":
        print(sp.unpack_info(d.request(sp.GET_INFO)[1]))
    elif a.cmd == "rev":
        print(d.request(sp.GET_REV)[1].decode("ascii", "replace"))
    elif a.cmd == "setrev":
        rev = (a.arg or "").encode("ascii")
        if len(rev) != 8:
            sys.exit("revision must be exactly 8 characters")
        _, p = d.request(sp.SET_REV, rev, timeout=3.0)
        print("OK" if p[0] == 0 else "FLASH ERROR", p[1:].decode("ascii", "replace"))
    elif a.cmd in ("config", "acquire"):
        cfg = sp.pack_config(a.sr, a.ss, a.pt, a.mode, a.edge, a.level, a.hyst, a.ph, 0, a.tp)
        print(sp.unpack_config(d.request(sp.SET_CONFIG, cfg)[1]))
        if a.cmd == "acquire":
            r = sp.unpack_acquire(d.request(sp.ACQUIRE, timeout=10.0)[1])
            s = r.pop("samples")
            print(r, "first samples:", list(s[:16]))
            if a.csv:
                with open(a.csv, "w") as f:
                    f.write("index,time_s,code\n")
                    for i, v in enumerate(s):
                        f.write(f"{i},{(i - r['pt']) / r['sr']:.9e},{v}\n")
                print("wrote", a.csv)
    elif a.cmd == "text":
        d.request(sp.TEXT)
        print("back in text mode")


if __name__ == "__main__":
    main()
