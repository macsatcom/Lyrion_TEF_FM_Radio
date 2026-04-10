# Lyrion TEF Radio

Stream FM radio to Lyrion Music Server using a TEF668X USB tuner (headless STM32 variant).

The TEF tuner handles FM demodulation in hardware and presents as two USB devices:
- A **serial control port** (`/dev/ttyACM0`) for tuning commands
- A **USB audio device** (ALSA) carrying the demodulated stereo audio

`fm-tef-daemon.py` reads audio directly from the ALSA device, encodes it to MP3 via ffmpeg, and pushes it to Icecast. Tuning is instant — a single serial command switches frequency without restarting ffmpeg.

---

## Architecture

```
TEF668X USB tuner
      │
      ├── /dev/ttyACM0  (serial control)
      │         ↑
      │    fm-tef-daemon  (HTTP tuning API)
      │         ↑
      │    LMS Plugin  (Radio menu, station list)
      │
      └── ALSA audio device
                ↓
             ffmpeg  (encode to MP3)
                ↓
             Icecast  (HTTP audio stream)
                ↑
           LMS Plugin
```

---

## Requirements

- Python 3.8+
- `pyserial` — `pip install pyserial`
- `ffmpeg` with `libmp3lame` support
- A running Icecast server
- TEF668X headless STM32 tuner flashed with [FM-DX-Tuner firmware](https://github.com/kkonradpl/FM-DX-Tuner)

---

## Setup

### 1. Find your device names

Plug in the TEF tuner, then:

```bash
# Serial control port (usually ttyACM0)
ls /dev/ttyACM*

# ALSA audio device name — the tuner is a capture (recording) device
arecord -l
```

The tuner presents as a USB audio **capture** device, not a playback device.
`aplay -l` will not show it. The output from `arecord -l` will look something like:

```
card 2: Tuner [FM-DX Tuner], device 0: USB Audio [USB Audio]
```

You can verify audio is working before configuring the daemon:
```bash
# Listen directly (pipe capture → playback)
arecord -D hw:CARD=Tuner,DEV=0 -f S16_LE -r 48000 -c 2 - | aplay -

# Or record 5 seconds to a file
arecord -D hw:CARD=Tuner,DEV=0 -f S16_LE -r 48000 -c 2 -d 5 test.wav && aplay test.wav
```

Your ALSA device string is then `hw:CARD=FMDX,DEV=0`.

### 2. Configure the daemon

Edit the constants at the top of `daemon/fm-tef-daemon.py`:

```python
SERIAL_PORT        = "/dev/ttyACM0"         # from step 1
AUDIO_DEVICE       = "hw:CARD=FMDX,DEV=0"  # from step 1

ICECAST_HOST       = "localhost"
ICECAST_PORT       = 8000
ICECAST_MOUNT      = "/fm"
ICECAST_SOURCE     = "your-source-password"
ICECAST_ADMIN_USER = "admin"
ICECAST_ADMIN_PASS = "your-admin-password"

STARTUP_FREQ       = 90800000               # Hz (90.8 MHz)
```

All values can also be set as environment variables (same names) instead of editing the file.

### 3. Run the daemon

```bash
pip install pyserial
python3 daemon/fm-tef-daemon.py
```

Optional CLI flags:

```bash
python3 daemon/fm-tef-daemon.py \
  --serial /dev/ttyACM0 \
  --audio-device hw:CARD=FMDX,DEV=0
```

### 4. Test the API

```bash
curl http://localhost:8080/status
curl -X POST "http://localhost:8080/tune?freq=103900000"   # 103.9 MHz
```

Open `http://your-icecast-host:8000/fm` in a media player to verify audio.

### 5. Install as a systemd service

Edit the `Environment=` lines in `daemon/fm-tef-daemon.service` to match your setup (same values as step 2), then:

```bash
sudo cp daemon/fm-tef-daemon.py /usr/local/bin/fm-tef-daemon.py
sudo chmod +x /usr/local/bin/fm-tef-daemon.py
sudo cp daemon/fm-tef-daemon.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now fm-tef-daemon
sudo journalctl -u fm-tef-daemon -f
```

### 6. Install the LMS plugin

The LMS plugin from [Lyrion FM Radio](https://github.com/macsatcom/Lyrion_FM_Radio) works without any changes — the HTTP API is identical. Copy it into your LMS plugins directory:

```bash
cp -r /path/to/Lyrion_FM_Radio/LMSPlugin/FMRadio /config/cache/Plugins/
# Restart LMS, then configure via Settings → Plugins → FM Radio
```

Point the plugin's **daemon URL** to `http://your-host:8080` and the **Icecast URL** to `http://your-icecast-host:8000/fm`.

---

## HTTP API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/status` | JSON with current status, frequency, and RDS PI code |
| GET | `/listen/90.8` | Tune (MHz) + redirect to Icecast stream |
| GET | `/listen/90800000` | Tune (Hz) + redirect |
| POST | `/tune?freq=90800000` | Tune without redirect |
| POST | `/stop` | Send shutdown command to tuner |

---

## Differences from the RTL-SDR version

| | Lyrion FM Radio (RTL-SDR) | Lyrion TEF Radio (this) |
|--|--|--|
| Demodulation | NGSoftFM (software) | TEF668X hardware |
| Audio source | Named pipe (FIFO) | ALSA USB audio device |
| Tuning | Restarts NGSoftFM process | Single serial command, ffmpeg uninterrupted |
| RDS | Not decoded | PI code parsed from serial stream |
| Dependencies | softfm binary | pyserial |
