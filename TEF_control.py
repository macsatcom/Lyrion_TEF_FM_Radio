#!/usr/bin/env python3
"""
TEF_control.py — Command-line interface for the headless TEF668X USB tuner.

All features of the FM-DX-Tuner serial protocol are implemented as subcommands.
Run with --help or <subcommand> --help for usage details.

Dependencies: pip install pyserial

Examples:
  TEF_control.py tune 90.8
  TEF_control.py tune 103.9 --volume 80 --deemphasis 50us
  TEF_control.py scan --from 87.5 --to 108 --step 0.1
  TEF_control.py monitor
  TEF_control.py quality --count 10
"""

import sys
import time
import signal
import argparse
import serial
import json as _json_mod

# ─── Defaults ─────────────────────────────────────────────────────────────────

DEFAULT_PORT    = "/dev/ttyACM0"
DEFAULT_BAUD    = 115200
DEFAULT_TIMEOUT = 3.0   # seconds to wait for a command echo

# ─── Tuner class ──────────────────────────────────────────────────────────────

class TEFTuner:
    def __init__(self, port, baud, startup=True, verbose=False):
        self.verbose  = verbose
        self.ser      = serial.Serial(port, baud, timeout=0.5)
        if startup:
            self._handshake()

    def close(self):
        self.ser.close()

    # ── Low-level I/O ──

    def _send(self, cmd):
        line = cmd + "\n"
        if self.verbose:
            print(f"  → {cmd!r}", file=sys.stderr)
        self.ser.write(line.encode())
        self.ser.flush()

    def _readline(self):
        line = self.ser.readline().decode(errors="replace").strip()
        if self.verbose and line:
            print(f"  ← {line!r}", file=sys.stderr)
        return line

    def _read_until(self, predicate, timeout=DEFAULT_TIMEOUT):
        """Read lines until predicate(line) returns True or timeout."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self._readline()
            if line and predicate(line):
                return line
        return None

    # ── Handshake ──

    def _handshake(self):
        self.ser.flushInput()
        self._send("x")
        result = self._read_until(lambda l: l == "OK", timeout=4.0)
        if result is None:
            raise RuntimeError(
                "No OK from tuner. Is it connected and is the firmware running?\n"
                "Try: ls /dev/ttyACM*"
            )

    # ── Commands that echo a single confirmation line ──

    def send_simple(self, cmd, expect_prefix, timeout=DEFAULT_TIMEOUT):
        """Send a command and return the first response line starting with expect_prefix."""
        self._send(cmd)
        deadline = time.monotonic() + timeout
        lines = []
        while time.monotonic() < deadline:
            line = self._readline()
            if line:
                lines.append(line)
                if line.startswith(expect_prefix):
                    return line
        return lines[-1] if lines else None

    def send_tune(self, freq_khz):
        """Send T<kHz> and collect all confirmation lines (M, T, V may all appear)."""
        self._send(f"T{freq_khz}")
        responses = {}
        deadline = time.monotonic() + DEFAULT_TIMEOUT
        while time.monotonic() < deadline:
            line = self._readline()
            if not line:
                continue
            c = line[0]
            if c in ('M', 'T', 'V', 'A', 'D', 'W'):
                responses[c] = line[1:]
                if c == 'T':
                    # T is always the last meaningful echo after a tune
                    time.sleep(0.05)   # collect any trailing echoes
                    while True:
                        extra = self._readline()
                        if not extra:
                            break
                        responses[extra[0]] = extra[1:]
                    break
        return responses

    def read_quality_line(self, timeout=2.0):
        """Wait for and return a parsed quality line."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self._readline()
            if line.startswith('S'):
                return _parse_quality(line)
        return None

    def stream_lines(self, timeout=None):
        """Generator: yield raw lines from the tuner. Runs until timeout or KeyboardInterrupt."""
        deadline = time.monotonic() + timeout if timeout else None
        while True:
            if deadline and time.monotonic() > deadline:
                break
            line = self._readline()
            if line:
                yield line

# ─── Parsers ──────────────────────────────────────────────────────────────────

def parse_freq(raw):
    """
    Parse a user-supplied frequency. Accepts:
      MHz float:  90.8, 88.1, 103.9
      kHz int:    90800, 88100
    Returns frequency in kHz, or raises ValueError.
    """
    try:
        val = float(raw)
    except ValueError:
        raise ValueError(f"Invalid frequency: {raw!r}")
    freq_khz = int(val * 1000) if val < 2200 else int(val)
    if not (144 <= freq_khz <= 108000):
        raise ValueError(f"Frequency {freq_khz} kHz out of range (144 kHz – 108 MHz)")
    return freq_khz

def _parse_quality(line):
    """Parse an S-line into a dict."""
    # Format: S<flag><rssi>,<cci>,<aci>,<bw>
    flag = line[1]
    parts = line[2:].split(',')
    stereo_output = flag in ('s', 'm')
    stereo_signal = flag in ('s', 'S')
    try:
        return {
            "stereo_output": stereo_output,
            "stereo_signal": stereo_signal,
            "rssi":          float(parts[0]),
            "cci":           int(parts[1]),
            "aci":           int(parts[2]) if len(parts) > 2 else -1,
            "bw":            int(parts[3]) if len(parts) > 3 else -1,
        }
    except (ValueError, IndexError):
        return None

def _parse_scan_line(line):
    """Parse a U-line (scan result) into list of (freq_khz, rssi) tuples."""
    results = []
    body = line[1:]   # strip leading 'U'
    for entry in body.split(','):
        entry = entry.strip()
        if '=' in entry:
            try:
                f, r = entry.split('=', 1)
                results.append((int(f), float(r)))
            except ValueError:
                pass
    return results

def _freq_display(freq_khz):
    if freq_khz >= 65000:
        return f"{freq_khz / 1000:.1f} MHz"
    return f"{freq_khz} kHz"

# ─── Formatters ───────────────────────────────────────────────────────────────

def _quality_str(q):
    stereo = "stereo" if q["stereo_signal"] else "mono"
    output = "(stereo out)" if q["stereo_output"] else "(mono out)"
    cci_str = f"CCI={q['cci']:3d}" if q["cci"] >= 0 else "CCI=n/a"
    aci_str = f"ACI={q['aci']:3d}" if q["aci"] >= 0 else "ACI=n/a"
    bw_str  = f"BW={q['bw']} kHz" if q["bw"] >= 0 else "BW=auto"
    return f"RSSI={q['rssi']:6.2f} dBf  {cci_str}  {aci_str}  {bw_str}  {stereo} {output}"

# ─── Subcommand handlers ──────────────────────────────────────────────────────

def cmd_tune(args, tuner):
    freq_khz = parse_freq(args.freq)
    responses = tuner.send_tune(freq_khz)

    freq_label = _freq_display(freq_khz)

    if args.json:
        out = {"freq_khz": int(responses.get('T', str(freq_khz)).split(',')[0])}
        if 'M' in responses:
            out["mode"] = "FM" if responses['M'] == '0' else "AM"
        print(_json_mod.dumps(out))
        return

    t_val = responses.get('T', '')
    actual_khz = int(t_val.split(',')[0]) if t_val else freq_khz
    step = t_val.split(',')[1] if ',' in t_val else '?'
    mode_raw = responses.get('M')
    mode_str = (" (FM)" if mode_raw == '0' else " (AM)") if mode_raw else ""

    print(f"Tuned to {_freq_display(actual_khz)}{mode_str}  [step={step} kHz]")

    # Apply any extra settings requested alongside tune
    if args.volume is not None:
        r = tuner.send_simple(f"Y{args.volume}", 'Y')
        print(f"Volume: {args.volume}")

    if args.deemphasis is not None:
        val = {"50us": 0, "75us": 1, "off": 2}[args.deemphasis]
        tuner.send_simple(f"D{val}", 'D')
        print(f"De-emphasis: {args.deemphasis}")

    if args.output is not None:
        val = {"stereo": 0, "mono": 1, "mpx": 2}[args.output]
        tuner.send_simple(f"B{val}", 'B')
        print(f"Output: {args.output}")


def cmd_mode(args, tuner):
    val = 0 if args.mode.lower() == "fm" else 1
    r = tuner.send_simple(f"M{val}", 'M')
    print(f"Mode: {args.mode.upper()}")


def cmd_volume(args, tuner):
    r = tuner.send_simple(f"Y{args.level}", 'Y')
    if args.json:
        print(_json_mod.dumps({"volume": args.level}))
    else:
        print(f"Volume: {args.level}/100")


def cmd_deemphasis(args, tuner):
    val = {"50us": 0, "75us": 1, "off": 2}[args.value]
    tuner.send_simple(f"D{val}", 'D')
    if not args.json:
        print(f"De-emphasis: {args.value}")


def cmd_agc(args, tuner):
    r = tuner.send_simple(f"A{args.level}", 'A')
    if not args.json:
        print(f"AGC: {args.level}")


def cmd_bandwidth(args, tuner):
    val = 0 if args.value.lower() == "auto" else int(args.value)
    r = tuner.send_simple(f"W{val}", 'W')
    if not args.json:
        label = "auto" if val == 0 else f"{val} Hz"
        print(f"Bandwidth: {label}")


def cmd_alignment(args, tuner):
    # Rounds to nearest 6 dB step (firmware does this internally too)
    val = round(args.db / 6) * 6
    val = max(0, min(36, val))
    r = tuner.send_simple(f"V{val}", 'V')
    if not args.json:
        print(f"Alignment (attenuation): {val} dB")


def cmd_squelch(args, tuner):
    raw = args.value.lower()
    if raw == "off":
        val = 0
    elif raw == "stereo":
        val = -1
    else:
        val = int(raw)
    r = tuner.send_simple(f"Q{val}", 'Q')
    if not args.json:
        labels = {0: "off", -1: "auto-stereo"}
        print(f"Squelch: {labels.get(val, f'RSSI > {val} dBf')}")


def cmd_output(args, tuner):
    val = {"stereo": 0, "mono": 1, "mpx": 2}[args.mode]
    r = tuner.send_simple(f"B{val}", 'B')
    if not args.json:
        print(f"Output mode: {args.mode}")


def cmd_quality(args, tuner):
    if args.interval is not None:
        tuner.send_simple(f"I{args.interval}", 'I')

    count = args.count
    collected = []

    try:
        i = 0
        for line in tuner.stream_lines(timeout=args.timeout):
            if not line.startswith('S'):
                continue
            q = _parse_quality(line)
            if q is None:
                continue
            collected.append(q)
            if not args.json:
                print(_quality_str(q))
            i += 1
            if count and i >= count:
                break
    except KeyboardInterrupt:
        pass

    if args.json:
        print(_json_mod.dumps(collected, indent=2))


def _collect_rds_ps(tuner, freq_khz: int, wait_sec: float) -> str:
    """
    Tune to freq_khz and collect RDS group-0 lines until we have a complete
    8-char PS name (all four 2-char segments seen) or wait_sec elapses.
    Returns the PS name string, or '' if nothing arrived in time.

    Quality reports (S-lines) are suppressed during the wait to avoid
    drowning out the RDS groups in the serial stream.
    """
    # Flush any residual scan output / quality reports from the buffer
    tuner.ser.reset_input_buffer()

    # Silence quality reports — they arrive every 66 ms and make it hard
    # to catch the much rarer RDS groups in the readline loop.
    tuner.send_simple("I0", "I")

    # Send tune command and wait only for the T-echo — do NOT use send_tune()
    # here because send_tune() drains the buffer for up to ~0.5 s after the
    # echo, silently discarding any RDS groups that arrive in that window.
    tuner._send(f"T{freq_khz}")
    tuner._read_until(lambda l: l.startswith('T'), timeout=DEFAULT_TIMEOUT)

    ps = [' '] * 8          # 8-char Programme Service name
    seen_segs = set()
    deadline  = time.monotonic() + wait_sec

    while time.monotonic() < deadline:
        line = tuner._readline()
        if not line:
            continue

        # Skip anything that isn't an RDS group line
        if not line.startswith('R'):
            continue

        # Legacy RDS format: R<B:4hex><C:4hex><D:4hex><err:2hex>  (14 chars after R)
        if len(line) < 15:
            continue
        try:
            B = int(line[1:5],  16)
            D = int(line[9:13], 16)
        except ValueError:
            continue

        group_type = (B >> 12) & 0xF
        if group_type != 0:
            continue   # only interested in group 0 (PS name)

        seg = B & 0x3   # 2-bit segment address: 0-3 → chars 0-1, 2-3, 4-5, 6-7
        c1  = (D >> 8) & 0xFF
        c2  =  D       & 0xFF
        if 0x20 <= c1 < 0x7F:
            ps[seg * 2]     = chr(c1)
        if 0x20 <= c2 < 0x7F:
            ps[seg * 2 + 1] = chr(c2)
        seen_segs.add(seg)

        if seen_segs == {0, 1, 2, 3}:
            break   # all four segments received — PS name complete

    # Re-enable quality reports at default rate before returning
    tuner.send_simple("I66", "I")

    name = ''.join(ps).strip()
    return name


def cmd_scan(args, tuner):
    from_khz = int(parse_freq(str(args.freq_from)) / 10) * 10   # round to 10 kHz
    to_khz   = int(parse_freq(str(args.freq_to))   / 10) * 10
    step_khz = int(float(args.step) * 1000) if float(args.step) < 100 else int(args.step)
    bw_hz    = args.bandwidth

    tuner._send(f"Sa{from_khz}")
    tuner._send(f"Sb{to_khz}")
    tuner._send(f"Sc{step_khz}")
    if bw_hz:
        tuner._send(f"Sw{bw_hz}")

    cmd = "Sm" if args.repeat else "S"
    tuner._send(cmd)

    results = []
    passes  = 0

    print(f"Scanning {_freq_display(from_khz)} → {_freq_display(to_khz)}, "
          f"step={step_khz} kHz  (Ctrl+C to stop)\n")

    try:
        for line in tuner.stream_lines(timeout=args.timeout):
            if not line.startswith('U'):
                continue

            passes += 1
            batch = _parse_scan_line(line)
            results = batch   # replace with latest pass

            if args.json:
                continue

            # Display as a simple bar chart
            print(f"Pass {passes}:")
            for freq_khz, rssi in batch:
                if rssi < args.threshold:
                    continue
                bar_len = max(0, int((rssi + 10) * 1.5))
                bar = "█" * min(bar_len, 40)
                print(f"  {_freq_display(freq_khz):>9}  {rssi:6.2f} dBf  {bar}")
            print()

            if not args.repeat:
                break

    except KeyboardInterrupt:
        tuner._send("")   # cancel scan

    # ── RDS name resolution ───────────────────────────────────────────────────
    # Filter to stations above threshold first, then tune each and wait for PS.
    stations = [(f, r) for f, r in results if r >= args.threshold]

    if args.rds and stations:
        rds_wait = args.rds_time

        # Send an explicit scan-cancel and flush before starting tune sequence.
        # The scanner may still have buffered output even after the U-line.
        tuner._send("")
        time.sleep(0.1)
        tuner.ser.reset_input_buffer()

        print(f"Resolving RDS names (up to {rds_wait:.0f} s per station) …\n")
        named = []
        for freq_khz, rssi in sorted(stations, key=lambda x: -x[1]):
            print(f"  {_freq_display(freq_khz):>9}  …", end=' ', flush=True)
            ps = _collect_rds_ps(tuner, freq_khz, rds_wait)
            label = ps if ps else _freq_display(freq_khz)
            print(label)
            named.append((freq_khz, rssi, label))
        stations_named = named
    else:
        stations_named = [(f, r, _freq_display(f)) for f, r in stations]

    # ── Output ────────────────────────────────────────────────────────────────
    if args.json:
        out = [
            {"freq_mhz": round(f / 1000, 3), "rssi": r, "name": n}
            for f, r, n in stations_named
        ]
        print(_json_mod.dumps(out, indent=2))
    elif stations_named:
        print(f"\nStations above {args.threshold} dBf:")
        for freq_khz, rssi, name in sorted(stations_named, key=lambda x: -x[1]):
            print(f"  {_freq_display(freq_khz):>9}  {rssi:6.2f} dBf  {name}")


def cmd_monitor(args, tuner):
    """Display all serial output from the tuner in real time."""
    if args.no_quality:
        tuner.send_simple("I0", 'I')
    elif args.interval is not None:
        tuner.send_simple(f"I{args.interval}", 'I')

    print("Monitoring tuner output (Ctrl+C to stop)...\n")

    try:
        for line in tuner.stream_lines(timeout=args.timeout):
            if not line:
                continue

            c = line[0]

            if c == 'S':
                if args.no_quality:
                    continue
                q = _parse_quality(line)
                if q:
                    if args.json:
                        print(_json_mod.dumps({"type": "quality", **q}))
                    else:
                        print(f"[quality]  {_quality_str(q)}")

            elif c == 'P':
                pi = line[1:]
                if args.json:
                    print(_json_mod.dumps({"type": "pi", "pi": pi}))
                else:
                    certain = pi.rstrip('?')
                    errors  = len(pi) - len(certain)
                    conf    = "uncertain" if errors else "confirmed"
                    print(f"[rds/PI]   {certain}  ({conf})")

            elif c == 'R':
                if args.json:
                    print(_json_mod.dumps({"type": "rds", "raw": line[1:]}))
                else:
                    print(f"[rds/grp]  {line[1:]}")

            elif c == 'T':
                parts = line[1:].split(',')
                freq_str = _freq_display(int(parts[0]))
                if args.json:
                    print(_json_mod.dumps({"type": "tune", "freq_khz": int(parts[0])}))
                else:
                    print(f"[tune]     {freq_str}")

            elif c == 'M':
                mode_str = "FM" if line[1:] == '0' else "AM"
                if not args.json:
                    print(f"[mode]     {mode_str}")

            else:
                if not args.json:
                    print(f"[raw]      {line}")

    except KeyboardInterrupt:
        pass
    finally:
        if args.no_quality:
            tuner.send_simple("I66", 'I')


def cmd_rds(args, tuner):
    """Monitor RDS data only (filters out quality reports)."""
    print("Waiting for RDS data (Ctrl+C to stop)...\n")
    try:
        for line in tuner.stream_lines(timeout=args.timeout):
            if line.startswith('P'):
                pi = line[1:]
                certain = pi.rstrip('?')
                errors  = len(pi) - len(certain)
                conf = f"  [{'confirmed' if errors == 0 else f'{errors} error(s)'}]"
                if args.json:
                    print(_json_mod.dumps({"type": "pi", "pi": certain, "errors": errors}))
                else:
                    print(f"PI code:   {certain}{conf}")

            elif line.startswith('R'):
                if args.json:
                    print(_json_mod.dumps({"type": "rds_group", "raw": line[1:]}))
                else:
                    print(f"RDS group: {line[1:]}")
    except KeyboardInterrupt:
        pass


def cmd_shutdown(args, tuner):
    tuner._send("X")
    print("Tuner shutdown.")


def cmd_raw(args, tuner):
    """Send a raw command string and print responses for a short window."""
    tuner._send(args.command)
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        line = tuner._readline()
        if line:
            print(line)

# ─── CLI definition ───────────────────────────────────────────────────────────

def build_parser():
    parser = argparse.ArgumentParser(
        prog="TEF_control.py",
        description="Control a headless TEF668X FM/AM USB tuner via serial.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
examples:
  %(prog)s tune 90.8
  %(prog)s tune 103.9 --volume 75 --deemphasis 50us
  %(prog)s tune 810     # AM — 810 kHz
  %(prog)s volume 80
  %(prog)s quality --count 5
  %(prog)s quality --interval 500
  %(prog)s scan
  %(prog)s scan --from 87.5 --to 108 --step 0.1 --threshold 10
  %(prog)s scan --threshold 5 --rds
  %(prog)s scan --threshold 5 --rds --rds-time 12
  %(prog)s scan --repeat
  %(prog)s monitor
  %(prog)s monitor --no-quality
  %(prog)s rds
  %(prog)s shutdown
  %(prog)s raw "Y80"
""",
    )

    parser.add_argument(
        "--port", "-p", default=DEFAULT_PORT, metavar="PORT",
        help=f"Serial port (default: {DEFAULT_PORT}). List: ls /dev/ttyACM*",
    )
    parser.add_argument(
        "--baud", "-b", type=int, default=DEFAULT_BAUD, metavar="BAUD",
        help=f"Baud rate (default: {DEFAULT_BAUD})",
    )
    parser.add_argument(
        "--no-startup", action="store_true",
        help="Skip the startup handshake (if tuner is already running)",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Print raw serial I/O to stderr",
    )
    parser.add_argument(
        "--json", action="store_true",
        help="Output results as JSON (for scripting)",
    )

    sub = parser.add_subparsers(dest="cmd", metavar="command")
    sub.required = True

    # ── tune ──
    p = sub.add_parser("tune", help="Tune to a frequency")
    p.add_argument("freq", help="Frequency in MHz (90.8) or kHz (90800)")
    p.add_argument("--volume", "-y", type=int, metavar="0-100",
                   help="Set volume after tuning")
    p.add_argument("--deemphasis", "-d", choices=["50us", "75us", "off"],
                   help="Set FM de-emphasis")
    p.add_argument("--output", "-o", choices=["stereo", "mono", "mpx"],
                   help="Set audio output mode")

    # ── mode ──
    p = sub.add_parser("mode", help="Set reception mode (FM or AM)")
    p.add_argument("mode", choices=["fm", "am", "FM", "AM"])

    # ── volume ──
    p = sub.add_parser("volume", help="Set audio volume")
    p.add_argument("level", type=int, metavar="0-100")

    # ── deemphasis ──
    p = sub.add_parser("deemphasis", help="Set FM de-emphasis time constant")
    p.add_argument("value", choices=["50us", "75us", "off"],
                   help="50us = European standard, 75us = US standard, off = disabled")

    # ── agc ──
    p = sub.add_parser("agc", help="Set RF AGC level")
    p.add_argument("level", type=int, choices=[0, 1, 2, 3],
                   help="0 = minimum gain reduction, 3 = maximum")

    # ── bandwidth ──
    p = sub.add_parser("bandwidth", help="Set IF filter bandwidth")
    p.add_argument("value", metavar="Hz|auto",
                   help="Bandwidth in Hz (e.g. 200000 = 200 kHz), or 'auto' for adaptive")

    # ── alignment ──
    p = sub.add_parser("alignment", help="Set antenna input attenuation (0–36 dB in 6 dB steps)")
    p.add_argument("db", type=int, metavar="dB",
                   help="Attenuation in dB (0, 6, 12, 18, 24, 30, 36)")

    # ── squelch ──
    p = sub.add_parser("squelch", help="Set squelch mode")
    p.add_argument("value", metavar="off|stereo|<rssi>",
                   help="off = disabled | stereo = mute when not stereo | "
                        "<number> = RSSI threshold in dBf")

    # ── output ──
    p = sub.add_parser("output", help="Set audio output mode")
    p.add_argument("mode", choices=["stereo", "mono", "mpx"],
                   help="stereo = L+R | mono = forced mono | mpx = raw MPX signal")

    # ── quality ──
    p = sub.add_parser("quality", help="Display signal quality readings")
    p.add_argument("--count", "-n", type=int, default=0, metavar="N",
                   help="Number of readings (default: run until Ctrl+C)")
    p.add_argument("--interval", "-i", type=int, metavar="ms",
                   help="Set reporting interval in ms (1–1000, default: 66)")
    p.add_argument("--timeout", "-t", type=float, default=None, metavar="sec",
                   help="Stop after this many seconds")

    # ── scan ──
    p = sub.add_parser("scan", help="Scan a frequency range and report signal levels")
    p.add_argument("--from", dest="freq_from", default="87.5", metavar="MHz",
                   help="Start frequency in MHz (default: 87.5)")
    p.add_argument("--to", dest="freq_to", default="108.0", metavar="MHz",
                   help="End frequency in MHz (default: 108.0)")
    p.add_argument("--step", default="0.1", metavar="MHz",
                   help="Step size in MHz (default: 0.1 = 100 kHz)")
    p.add_argument("--bandwidth", type=int, default=0, metavar="Hz",
                   help="IF bandwidth during scan in Hz (default: 0 = auto)")
    p.add_argument("--threshold", type=float, default=0.0, metavar="dBf",
                   help="Only show stations above this RSSI level (default: 0 dBf)")
    p.add_argument("--repeat", action="store_true",
                   help="Repeat scan continuously (Ctrl+C to stop)")
    p.add_argument("--timeout", type=float, default=120.0, metavar="sec",
                   help="Scan timeout in seconds (default: 120)")
    p.add_argument("--rds", action="store_true",
                   help="After scan, tune each found station and resolve its RDS PS name")
    p.add_argument("--rds-time", type=float, default=8.0, metavar="sec",
                   help="Max seconds to wait for RDS PS name per station (default: 8)")

    # ── monitor ──
    p = sub.add_parser("monitor", help="Display all tuner output in real time")
    p.add_argument("--interval", "-i", type=int, metavar="ms",
                   help="Set quality reporting interval in ms")
    p.add_argument("--no-quality", action="store_true",
                   help="Suppress signal quality lines (show RDS and events only)")
    p.add_argument("--timeout", type=float, default=None, metavar="sec",
                   help="Stop after this many seconds")

    # ── rds ──
    p = sub.add_parser("rds", help="Monitor RDS data only (PI codes and groups)")
    p.add_argument("--timeout", type=float, default=None, metavar="sec",
                   help="Stop after this many seconds")

    # ── shutdown ──
    sub.add_parser("shutdown", help="Send shutdown command to tuner")

    # ── raw ──
    p = sub.add_parser("raw", help="Send a raw serial command and print responses")
    p.add_argument("command", help="Command string without newline, e.g. 'Y80' or 'T90800'")

    return parser

# ─── Entrypoint ───────────────────────────────────────────────────────────────

def main():
    parser = build_parser()
    args   = parser.parse_args()

    # Propagate global flags to subcommand args namespace
    if not hasattr(args, 'json'):
        args.json = False

    try:
        tuner = TEFTuner(
            port    = args.port,
            baud    = args.baud,
            startup = not args.no_startup,
            verbose = args.verbose,
        )
    except serial.SerialException as e:
        print(f"Error: cannot open {args.port}: {e}", file=sys.stderr)
        print(f"Hint:  ls /dev/ttyACM*  or use --port", file=sys.stderr)
        sys.exit(1)
    except RuntimeError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    signal.signal(signal.SIGINT, signal.default_int_handler)  # raises KeyboardInterrupt in commands

    dispatch = {
        "tune":        cmd_tune,
        "mode":        cmd_mode,
        "volume":      cmd_volume,
        "deemphasis":  cmd_deemphasis,
        "agc":         cmd_agc,
        "bandwidth":   cmd_bandwidth,
        "alignment":   cmd_alignment,
        "squelch":     cmd_squelch,
        "output":      cmd_output,
        "quality":     cmd_quality,
        "scan":        cmd_scan,
        "monitor":     cmd_monitor,
        "rds":         cmd_rds,
        "shutdown":    cmd_shutdown,
        "raw":         cmd_raw,
    }

    try:
        dispatch[args.cmd](args, tuner)
    except KeyboardInterrupt:
        print("\nInterrupted.")
    finally:
        tuner.close()

if __name__ == "__main__":
    main()
