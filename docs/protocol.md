# Scope dongle – serial PC protocol (packet mode)

Protocol version **1**, firmware **0.4**. Reference implementation: `host/scope_proto.py`.

## Entering and leaving

| Action | How |
|---|---|
| Enter packet mode | Send the text command `SPC` (any line ending). The board answers `OK SPC …` in text, then switches. |
| Leave packet mode | Send a `TEXT` (0x09) packet. The board answers `0x89` and returns to the text command line. |
| Hard reset | btn0: text mode, 921600 baud, default settings. |

The serial link is 921600 8N1 by default (`BR=` in text mode changes it; the setting carries into packet mode).

## Frame format

Both directions use the same frame. All multi-byte fields are little-endian.

| Field | Size | Value |
|---|---|---|
| SYNC | 1 | `0xA5` |
| TYPE | 1 | command; response = command \| `0x80`, or `0xFF` = NAK |
| LEN | 2 | payload length in bytes (host → device: 0..64; device → host: 0..16396) |
| PAYLOAD | LEN | |
| CRC | 2 | CRC-16/CCITT-FALSE over TYPE, LEN and PAYLOAD |

**CRC-16/CCITT-FALSE:** polynomial 0x1021, initial value 0xFFFF, no reflection, no final XOR.
Check value: ASCII `123456789` → `0x29B1`.

```c
uint16_t crc16(const uint8_t *p, size_t n, uint16_t crc /* = 0xFFFF */) {
    while (n--) {
        crc ^= (uint16_t)(*p++) << 8;
        for (int i = 0; i < 8; i++)
            crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : crc << 1;
    }
    return crc;
}
```

**Receiver rules (device):** bytes before SYNC are ignored. A frame that stalls for more than 30 ms
is dropped. LEN > 64 is answered with NAK immediately (the rest of that frame is then treated as
noise). The link is half-duplex: send one request, wait for its response.

## Commands

| TYPE | Name | Request payload | Response |
|---|---|---|---|
| `0x01` | PING | 0..64 bytes, any | `0x81`, same bytes echoed |
| `0x02` | GET_INFO | – | `0x82`, INFO (18 bytes) |
| `0x03` | SET_CONFIG | CONFIG_REQ (16 bytes) | `0x83`, CONFIG (20 bytes, effective values) |
| `0x04` | GET_CONFIG | – | `0x84`, CONFIG (20 bytes) |
| `0x05` | ACQUIRE | – | `0x85`, ACQ header (12 bytes) + N samples |
| `0x07` | GET_REV | – | `0x87`, 8 ASCII characters |
| `0x08` | SET_REV | 8 ASCII characters | `0x88`, status (0 ok, 1 flash error) + 8 characters read back |
| `0x09` | TEXT | – | `0x89`, empty; then text mode |
| | *(any other)* | | NAK |

### NAK (`0xFF`)

| Byte | Meaning |
|---|---|
| 0 | code: 1 CRC error, 2 bad length, 3 unknown type, 4 bad argument |
| 1 | TYPE of the rejected request |

### INFO (18 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | protocol version (1) |
| 1 | 1 | firmware major (0) |
| 2 | 1 | firmware minor (4) |
| 3 | 1 | ADC bits (8) |
| 4 | 4 | maximum sample rate, S/s (200 000 000) |
| 8 | 2 | maximum samples per capture (16384) |
| 10 | 8 | board revision, ASCII (`--------` if never written) |

### CONFIG_REQ (16 bytes, SET_CONFIG)

| Offset | Size | Field | Range |
|---|---|---|---|
| 0 | 4 | sample rate, S/s | > 0; rounded, see below |
| 4 | 2 | samples per capture (SS) | 1..16384 |
| 6 | 2 | pre-trigger samples (PT) | 0..SS-1 |
| 8 | 1 | trigger mode | 0 auto, 1 normal, 2 immediate |
| 9 | 1 | trigger edge | 0 rising, 1 falling |
| 10 | 1 | trigger level, ADC code | 0..255 |
| 11 | 1 | trigger hysteresis, codes | 0..255 |
| 12 | 1 | capture phase, 2.5 ns steps | 0..39, or 0xFF = automatic |
| 13 | 1 | ADC power-down | 0/1 |
| 14 | 1 | test pattern (ramp) | 0/1 |
| 15 | 1 | reserved | 0 |

Any field out of range → NAK code 4 and nothing is changed.

### CONFIG (20 bytes, SET/GET_CONFIG response)

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | effective sample rate, S/s |
| 4 | 4 | ADC clock, Hz |
| 8 | 2 | SS |
| 10 | 2 | PT |
| 12 | 1 | trigger mode |
| 13 | 1 | trigger edge |
| 14 | 1 | trigger level |
| 15 | 1 | hysteresis |
| 16 | 1 | effective capture phase |
| 17 | 1 | ADC power-down |
| 18 | 1 | test pattern |
| 19 | 1 | ADC clock mode (0 running, 1 held low, 2 held high) |

**Sample-rate rounding:** P = round(200 MHz / requested). If P ≤ 20 the ADC runs at 200 MHz / P
(200, 100, 66.7, 50, 40 … 10 MHz). Otherwise the ADC runs at 10 MHz and one of every
D = round(P / 20) samples is kept. Use the returned rate, not the requested one.

### ACQUIRE response

Header (12 bytes) followed by N sample bytes (unsigned ADC codes, oldest first).

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | status: 0 ok, 2 aborted |
| 1 | 1 | 1 = real trigger, 0 = auto-forced / immediate |
| 2 | 2 | sequence number (increments per ACQUIRE) |
| 4 | 4 | sample rate, S/s |
| 8 | 2 | PT = index of the trigger sample |
| 10 | 2 | N = number of samples that follow (0 if aborted) |

Sample *i* was taken at (*i* − PT) / sample-rate seconds relative to the trigger.

**Waiting and abort:** ACQUIRE returns when the capture completes. In auto mode the trigger is
forced after 100 ms. In normal mode the board waits for a trigger indefinitely; any byte sent
while it waits (by convention `0x18`) aborts the capture and the board answers with status 2, N = 0.

**Transfer time** at 921600 baud ≈ 11 µs per byte: 1024 samples ≈ 11 ms, 16384 ≈ 180 ms.

## Example

PING with payload `hi`:

```
host   → A5 01 02 00 68 69 39 29
device ← A5 81 02 00 68 69 xx xx
```

## Mapping to the PC application (`IScopeHardware`)

| PC app | Packet |
|---|---|
| `Info` | GET_INFO (`MaxSampleRate`, `AdcBits`, `RecordLength`) |
| `SetTimebase` | SET_CONFIG: sample rate from s/div × divisions / SS; `TriggerPosition` × SS → PT |
| `SetTrigger` | SET_CONFIG: level/hysteresis converted to codes, slope, mode (Single → normal, one ACQUIRE) |
| `Acquire` | ACQUIRE; `AcqInfo.Triggered`, `TriggerIndex` = PT, `Sequence`, `SampleRate` from the header; status 2 → `NoTrigger` |
