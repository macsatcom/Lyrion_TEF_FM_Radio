#!/usr/bin/env python3
"""
FM TEF Radio Daemon
Controls a TEF668X USB tuner via serial and streams audio to Icecast.
Provides an HTTP API compatible with the Lyrion FM Radio LMS plugin.

The TEF tuner (headless STM32 variant) presents as two USB devices:
  - USB CDC serial (/dev/ttyACM0)  — control commands (tune, mode, etc.)
  - USB audio class device (ALSA)  — I2S audio output, read directly by ffmpeg

Tuning does NOT restart ffmpeg. A tune command is sent over serial and the
hardware switches frequency instantly while audio keeps flowing.

Dependencies:
  pip install pyserial

Configuration: edit the constants below, or override via environment variables.
"""

import os
import serial
import threading
import time
import json
import subprocess
import signal
import argparse
import base64
import urllib.parse
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, urlencode

# ─── Configuration ────────────────────────────────────────────────────────────

# Serial port for the TEF tuner control interface (USB CDC)
# Default for STM32-based headless tuner. Use `ls /dev/ttyACM*` to find yours.
SERIAL_PORT        = os.environ.get("SERIAL_PORT",        "/dev/ttyACM0")
SERIAL_BAUD        = int(os.environ.get("SERIAL_BAUD",    "115200"))

# ALSA device name for the TEF tuner USB audio output.
# Find yours with: aplay -l  (look for the TEF/FMDX entry)
# Common examples: hw:CARD=FMDX,DEV=0   or simply  hw:1,0
AUDIO_DEVICE       = os.environ.get("AUDIO_DEVICE",       "hw:CARD=FMDX,DEV=0")

ICECAST_HOST       = os.environ.get("ICECAST_HOST",       "your-icecast-host")
ICECAST_PORT       = int(os.environ.get("ICECAST_PORT",   "8000"))
ICECAST_MOUNT      = os.environ.get("ICECAST_MOUNT",      "/fm")
ICECAST_SOURCE     = os.environ.get("ICECAST_SOURCE",     "your-source-password")
ICECAST_ADMIN_USER = os.environ.get("ICECAST_ADMIN_USER", "admin")
ICECAST_ADMIN_PASS = os.environ.get("ICECAST_ADMIN_PASS", "your-admin-password")

DAEMON_PORT        = int(os.environ.get("DAEMON_PORT",    "8080"))

# Default startup frequency in Hz (e.g. 90800000 = 90.8 MHz)
STARTUP_FREQ       = int(os.environ.get("STARTUP_FREQ",   "90800000"))

# ─── State ────────────────────────────────────────────────────────────────────

state = {
    "status": "stopped",
    "freq":   None,
    "pi":     None,   # RDS PI code (hex string), updated from serial stream
}

ffmpeg_proc  = None
serial_conn  = None
state_lock   = threading.Lock()
serial_lock  = threading.Lock()

# ─── Serial ───────────────────────────────────────────────────────────────────

def serial_open():
    global serial_conn
    serial_conn = serial.Serial(SERIAL_PORT, SERIAL_BAUD, timeout=1)
    time.sleep(0.1)
    print(f"[serial] opened {SERIAL_PORT} at {SERIAL_BAUD} baud")

def serial_send(cmd):
    """Send a single command line to the tuner, e.g. 'T90800' or 'M0'."""
    with serial_lock:
        if serial_conn and serial_conn.is_open:
            serial_conn.write((cmd + "\n").encode())
            serial_conn.flush()
            print(f"[serial] → {cmd}")
        else:
            print(f"[serial] WARNING: port not open, dropping command: {cmd}")

def serial_reader():
    """Background thread: reads responses from the tuner (RDS, signal quality, etc.)."""
    while True:
        try:
            if serial_conn and serial_conn.is_open:
                line = serial_conn.readline().decode(errors="replace").strip()
                if line:
                    _handle_serial_line(line)
            else:
                time.sleep(0.5)
        except Exception as e:
            print(f"[serial] read error: {e}")
            time.sleep(1)

def _handle_serial_line(line):
    if not line:
        return
    cmd = line[0]
    arg = line[1:]

    if cmd == 'x':
        # Startup confirmation from tuner
        print("[tuner] startup ready")

    elif cmd == 'X':
        # Tuner shutdown
        print("[tuner] shutdown")

    elif cmd == 'T':
        # Tuner reports current frequency (kHz)
        print(f"[tuner] freq={arg} kHz")

    elif cmd == 'P':
        # RDS PI code (hex, e.g. '3201' = DR P1)
        with state_lock:
            if state["pi"] != arg:
                state["pi"] = arg
                print(f"[rds] PI={arg}")

    elif cmd == 'S':
        # Signal quality report — ignore for now
        pass

    elif cmd == 'R':
        # RDS group data — ignore (would need librdsparser to decode)
        pass

# ─── Icecast metadata ─────────────────────────────────────────────────────────

def update_icecast_metadata(freq_hz):
    freq_mhz = freq_hz / 1_000_000
    title = f"{freq_mhz:.1f} MHz"
    try:
        params = urlencode({"mode": "updinfo", "mount": ICECAST_MOUNT, "song": title})
        url = f"http://{ICECAST_HOST}:{ICECAST_PORT}/admin/metadata?{params}"
        req = urllib.request.Request(url)
        creds = base64.b64encode(
            f"{ICECAST_ADMIN_USER}:{ICECAST_ADMIN_PASS}".encode()
        ).decode()
        req.add_header("Authorization", f"Basic {creds}")
        urllib.request.urlopen(req, timeout=3)
        print(f"[icecast] metadata updated: {title}")
    except Exception as e:
        print(f"[icecast] metadata update failed: {e}")

# ─── Audio pipeline ───────────────────────────────────────────────────────────

def start_ffmpeg(freq_hz=None):
    """Start ffmpeg reading from the TEF USB audio device and pushing to Icecast."""
    global ffmpeg_proc
    freq_mhz = f"{freq_hz / 1_000_000:.1f} MHz" if freq_hz else "FM Radio"
    ice_url = (
        f"icecast://source:{ICECAST_SOURCE}@{ICECAST_HOST}:{ICECAST_PORT}{ICECAST_MOUNT}"
        f"?ice-name={urllib.parse.quote(freq_mhz)}"
        f"&ice-description={urllib.parse.quote('FM Radio via TEF Tuner')}"
        f"&ice-genre=FM"
    )
    ffmpeg_proc = subprocess.Popen([
        "ffmpeg", "-loglevel", "error",
        "-f", "alsa",
        "-i", AUDIO_DEVICE,
        "-c:a", "libmp3lame", "-b:a", "192k",
        "-f", "mp3",
        ice_url,
    ])
    print(f"[ffmpeg] started (ALSA device: {AUDIO_DEVICE})")

def stop_ffmpeg():
    global ffmpeg_proc
    if ffmpeg_proc and ffmpeg_proc.poll() is None:
        ffmpeg_proc.terminate()
        try:
            ffmpeg_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            ffmpeg_proc.kill()
        ffmpeg_proc = None
        print("[ffmpeg] stopped")

# ─── Tuner control ────────────────────────────────────────────────────────────

def _hz_to_khz(freq_hz):
    """Convert Hz to kHz for the TEF serial protocol."""
    return freq_hz // 1000

def tune(freq_hz):
    """
    Tune to a new frequency.
    Sends a serial command to the TEF tuner — ffmpeg keeps running uninterrupted.
    """
    def _do():
        serial_send(f"T{_hz_to_khz(freq_hz)}")
        with state_lock:
            state["status"] = "playing"
            state["freq"]   = freq_hz
            state["pi"]     = None
        time.sleep(2)
        update_icecast_metadata(freq_hz)

    threading.Thread(target=_do, daemon=True).start()

def stop():
    serial_send("X")   # tuner shutdown command
    with state_lock:
        state["status"] = "stopped"
        state["freq"]   = None
        state["pi"]     = None

# ─── HTTP API ─────────────────────────────────────────────────────────────────

def _parse_freq(raw):
    """
    Parse a frequency string. Accepts MHz (float) or Hz (int).
    Returns frequency in Hz, or None if invalid / outside FM band (87.5–108 MHz).
    """
    try:
        val = float(raw)
        freq_hz = int(val * 1_000_000) if val < 2200 else int(val)
    except ValueError:
        return None
    if 87_500_000 <= freq_hz <= 108_000_000:
        return freq_hz
    return None

def _json(handler, code, data):
    body = json.dumps(data, indent=2).encode()
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", len(body))
    handler.end_headers()
    handler.wfile.write(body)

class FMHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(f"[http] {self.address_string()} {fmt % args}")

    def do_GET(self):
        parsed = urlparse(self.path)

        # GET /status
        if parsed.path == "/status":
            with state_lock:
                _json(self, 200, dict(state))

        # GET /listen/90.8  or  /listen/90800000
        elif parsed.path.startswith("/listen/"):
            raw = parsed.path[len("/listen/"):]
            freq_hz = _parse_freq(raw)
            if freq_hz:
                tune(freq_hz)
                self.send_response(302)
                self.send_header(
                    "Location",
                    f"http://{ICECAST_HOST}:{ICECAST_PORT}{ICECAST_MOUNT}"
                )
                self.end_headers()
            else:
                _json(self, 400, {"error": f"invalid or out-of-band frequency: {raw}"})

        else:
            _json(self, 404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        # POST /tune?freq=90800000
        if parsed.path == "/tune":
            raw = qs.get("freq", [None])[0]
            if not raw:
                _json(self, 400, {"error": "missing freq parameter"})
                return
            freq_hz = _parse_freq(raw)
            if not freq_hz:
                _json(self, 400, {"error": f"invalid or out-of-band frequency: {raw}"})
                return
            tune(freq_hz)
            _json(self, 200, {"ok": True, "freq": freq_hz})

        # POST /stop
        elif parsed.path == "/stop":
            stop()
            _json(self, 200, {"ok": True, "status": "stopped"})

        else:
            _json(self, 404, {"error": "not found"})

# ─── Entrypoint ───────────────────────────────────────────────────────────────

def shutdown_handler(sig, frame):
    print("\n[daemon] shutting down...")
    stop_ffmpeg()
    os._exit(0)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="FM TEF Radio Daemon")
    parser.add_argument(
        "-s", "--serial",
        default=SERIAL_PORT,
        metavar="PORT",
        help=f"Serial port for TEF tuner control (default: {SERIAL_PORT}). "
             "List candidates with: ls /dev/ttyACM*",
    )
    parser.add_argument(
        "-a", "--audio-device",
        default=AUDIO_DEVICE,
        metavar="DEVICE",
        help=f"ALSA audio device for TEF tuner output (default: {AUDIO_DEVICE}). "
             "List available devices with: aplay -l",
    )
    args = parser.parse_args()

    # Allow CLI args to override module-level config
    SERIAL_PORT  = args.serial
    AUDIO_DEVICE = args.audio_device

    signal.signal(signal.SIGINT,  shutdown_handler)
    signal.signal(signal.SIGTERM, shutdown_handler)

    print(f"[daemon] opening serial port {SERIAL_PORT}...")
    serial_open()

    # Start background thread to read tuner responses (RDS, signal quality, etc.)
    threading.Thread(target=serial_reader, daemon=True).start()

    # Give the tuner a moment after serial open, then initialise
    time.sleep(0.5)
    serial_send("M0")                            # FM mode (0 = FM, 1 = AM)
    serial_send(f"T{_hz_to_khz(STARTUP_FREQ)}")  # startup frequency

    print(f"[daemon] starting ffmpeg pipeline (reading from {AUDIO_DEVICE})...")
    start_ffmpeg(freq_hz=STARTUP_FREQ)

    with state_lock:
        state["status"] = "playing"
        state["freq"]   = STARTUP_FREQ

    time.sleep(2)
    update_icecast_metadata(STARTUP_FREQ)

    print(f"[daemon] HTTP API on port {DAEMON_PORT}")
    print(f"[daemon] tuned to {STARTUP_FREQ / 1_000_000:.1f} MHz")
    print("[daemon] endpoints:")
    print("  GET  /status")
    print("  GET  /listen/90.8       (MHz)")
    print("  GET  /listen/90800000   (Hz)")
    print("  POST /tune?freq=90800000")
    print("  POST /stop")

    server = HTTPServer(("0.0.0.0", DAEMON_PORT), FMHandler)
    server.serve_forever()
