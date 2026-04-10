# Headless TEF Tuner — Serial Protocol Reference

This document describes the serial communication protocol used by the
[FM-DX-Tuner firmware](https://github.com/kkonradpl/FM-DX-Tuner) on the headless STM32 TEF668X USB tuner.

---

## Connection

| Parameter | Value |
|-----------|-------|
| Device | `/dev/ttyACM0` (USB CDC, STM32) |
| Baud rate | 115200 |
| Data bits | 8 |
| Parity | None |
| Stop bits | 1 |

All messages — both commands and responses — are **newline-terminated ASCII strings** (`\n`).
Commands consist of a single letter followed immediately by a value, e.g. `T90800\n`.

---

## Frequency Units

All frequencies are in **kHz**.

| Band | Range |
|------|-------|
| FM (VHF) | 65000–108000 kHz (65–108 MHz) |
| AM (HF) | 144–27000 kHz (144 kHz–27 MHz) |

The `T` (tune) command auto-selects FM or AM based on which range the frequency falls in.
You do not need to send `M` before `T` unless you specifically want to force a mode change.

---

## Startup Handshake

The firmware boots into a waiting state and does nothing until it receives the startup command.

**1. Send startup:**
```
x\n
```

**2. Firmware responds:**
```
\nOK\n
```

After `OK`, the tuner is active and accepts all other commands. If you send `x` again while
already running, it responds with `\nOK\n` again (no side effects).

---

## Commands (Host → Tuner)

All commands are echoed back as a confirmation response with the effective value applied.

### Session control

| Command | Description |
|---------|-------------|
| `x\n` | Startup — wake up the tuner (required before any other command) |
| `X\n` | Shutdown — powers down tuner IC, firmware returns to waiting for `x` |
| `\n` | Cancel — abort any ongoing asynchronous operation (currently: scan) |

### Tuning

| Command | Values | Description |
|---------|--------|-------------|
| `T<kHz>\n` | 65000–108000 (FM) or 144–27000 (AM) | Tune to frequency. Auto-selects mode by range. |
| `M<mode>\n` | `0`=FM, `1`=AM | Explicitly set mode. Clamps frequency to new band. |

**Example:** Tune to 90.8 MHz:
```
T90800\n
```
Responses: `M0\n` (if mode changed), `T90800,10\n` (confirmed freq + step), `V0\n` (alignment).

### Audio

| Command | Values | Description |
|---------|--------|-------------|
| `Y<0–100>\n` | 0–100 | Volume in percent |
| `B<mode>\n` | `0`=stereo, `1`=mono, `2`=MPX | Audio output mode |
| `D<value>\n` | `0`=50 µs, `1`=75 µs, `2`=off | FM de-emphasis |

### Signal processing

| Command | Values | Description |
|---------|--------|-------------|
| `A<0–3>\n` | 0–3 | RF AGC level (higher = more gain reduction) |
| `W<Hz>\n` | Hz, `0`=auto | IF filter bandwidth. `0` = automatic (adaptive) |
| `V<dB>\n` | 0–36 (6 dB steps) | Antenna input attenuation in dB |
| `Q<value>\n` | `-1`=auto-stereo, `0`=off, `>0`=RSSI | Squelch. Negative: mute when not stereo. Positive: RSSI threshold. |

### Quality reporting

| Command | Values | Description |
|---------|--------|-------------|
| `I<ms>\n` | 0–1000 | Signal quality report interval in ms. `0` disables reporting. Default: 66 ms. |

### Frequency scan

Scan parameters must be set before starting. All frequencies in kHz.

| Command | Description |
|---------|-------------|
| `Sa<kHz>\n` | Set scan start frequency |
| `Sb<kHz>\n` | Set scan end frequency |
| `Sc<kHz>\n` | Set scan step size |
| `Sw<Hz>\n` | Set scan filter bandwidth |
| `S\n` | Start scan (single pass) |
| `Sm\n` | Start repeating scan (loops until cancelled) |
| `\n` | Cancel scan, return to previous frequency |

**Example:** Scan 87.5–108 MHz in 100 kHz steps:
```
Sa87500\n
Sb108000\n
Sc100\n
S\n
```

### Custom (TEF668X specific)

| Command | Description |
|---------|-------------|
| `G<xy>\n` | Custom features: `x`=channel equalizer (`0`/`1`), `y`=MPH suppression (`0`/`1`) |

---

## Responses (Tuner → Host)

### Command confirmations

After most commands, the tuner echoes back the effective (applied) value:

| Response | Description |
|----------|-------------|
| `M<mode>\n` | Current mode: `0`=FM, `1`=AM |
| `T<kHz>,<step_kHz>\n` | Current frequency and channel step size |
| `V<dB>\n` | Current antenna attenuation |
| `D<value>\n` | Current de-emphasis setting |
| `A<value>\n` | Current AGC level |
| `W<Hz>\n` | Current filter bandwidth (0 = auto) |
| `Y<value>\n` | Current volume |
| `Q<value>\n` | Current squelch setting |
| `B<mode>\n` | Current output mode |
| `I<ms>\n` | Current quality report interval |

### Signal quality (streaming)

Sent automatically at the configured interval (default ~66 ms):

```
S<flag><rssi>,<cci>,<aci>,<bw>\n
```

| Field | Description |
|-------|-------------|
| `flag` | Stereo/mono indicator (see table below) |
| `rssi` | Signal strength in dBf, decimal (e.g. `15.00`) |
| `cci` | Co-channel interference, 0–100 (`-1` if unavailable) |
| `aci` | Adjacent-channel interference, 0–100 (`-1` if manual BW set) |
| `bw` | Effective bandwidth in kHz (`-1` if unavailable) |

**Stereo flag values:**

| Flag | Output mode | Pilot detected |
|------|-------------|----------------|
| `s` | Stereo | Yes — currently stereo |
| `m` | Stereo | No — currently mono |
| `S` | Mono/MPX | Yes — would be stereo |
| `M` | Mono/MPX | No — mono |

**Example:** Stereo signal, 15 dBf, moderate CCI:
```
Ss15.00,42,-1,-1\n
```

### RDS — PI code

```
P<XXXX>[?...]\n
```

`XXXX` is the 4-digit hex PI code. Each `?` appended indicates one level of reception error/uncertainty
(0 `?` = clean, 2 `?` = uncertain). Emitted whenever the PI code is received or updated.

**Example:** DR P1 (PI code 3201, clean):
```
P3201\n
```

**Example:** Uncertain PI code:
```
P3201??\n
```

### RDS — group data

Two formats depending on firmware compile-time setting `TUNER_LEGACY_RDS_MSG`:

**New format** (`TUNER_LEGACY_RDS_MSG = false`):
```
R<A><B><C><D><err>\n
```

**Legacy format** (`TUNER_LEGACY_RDS_MSG = true`, default):
```
R<B><C><D><err>\n
```

Each block (`A`–`D`) is **4 hex characters** (16-bit). `err` is **2 hex characters** (8-bit error flags,
2 bits per block). Emitted for every valid RDS group received.

**Example** (legacy, group type 0A with station name):
```
R02014141CF\n
```

### Scan output

```
U<kHz>=<rssi>,<kHz>=<rssi>,...\n
```

One line per scan pass. Each entry is `frequency=rssi` separated by commas.
RSSI uses the same decimal dBf format as the quality report.

**Example:**
```
U87600=2.50,87700=-1.25,87800=18.75,...\n
```

---

## Typical Session

```
# 1. Startup
→ x
← \nOK

# 2. Tune to 90.8 MHz FM
→ T90800
← M0          (FM mode confirmed)
← T90800,10   (frequency + 10 kHz step confirmed)
← V0          (alignment = 0 dB)

# 3. Set volume and de-emphasis
→ Y80
← Y80
→ D0
← D0          (50 µs de-emphasis)

# 4. Streaming quality reports arrive automatically (~66 ms interval)
← Ss15.00,12,-1,-1
← Ss15.25,11,-1,-1
...

# 5. RDS arrives when a station transmits it
← P3201
← R02014141CF
← R0401424200
...

# 6. Retune to 103.9 MHz
→ T103900
← T103900,10
← V0

# 7. Shutdown
→ X
```

---

## Notes

- The firmware ignores unrecognised commands silently (no error response).
- Sending `T` with a frequency in the AM range automatically switches to AM mode and echoes `M1` first.
- Volume `Y` accepts 0–100 only; values > 100 are rejected silently.
- Bandwidth `W0` enables the adaptive (automatic) bandwidth algorithm in the TEF IC.
- Quality reports are suspended during an active scan.
- The `G` custom command is TEF668X-specific and has no effect on SAF7730/SAF775X builds.
