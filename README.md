# Lyrion TEF Radio

FM radio in Lyrion Music Server, powered by a TEF668X USB tuner.

The TEF tuner handles FM demodulation in hardware and presents as two USB devices:
- A **serial control port** (`/dev/ttyACM0`) — for tuning commands
- A **USB audio device** (ALSA) — demodulated stereo audio

---

## Architecture

Audio goes directly from the USB audio device into LMS via a pipe — **no Icecast server required**.

```
TEF668X USB tuner
      │
      ├── /dev/ttyACM0  (serial)
      │         └── tef-stream.pl  ─── tune command (T90800)
      │
      └── ALSA capture device
                └── ffmpeg (MP3 encode)
                        └── stdout pipe
                                └── LMS plugin  →  Squeezebox / squeezelite
```

When a station is selected in Lyrion:
1. `ProtocolHandler` spawns `tef-stream.pl`
2. `tef-stream.pl` sends a tune command over serial, then `exec()`s into ffmpeg
3. ffmpeg reads from the ALSA capture device and writes MP3 to stdout
4. LMS reads from the pipe and streams to the player

Station changes are instant — the TEF hardware switches frequency with a single serial command.

---

## Requirements

- **ffmpeg** with `libmp3lame`
- **Perl 5** (already present in LMS — no extra modules needed)
- **TEF668X headless STM32 tuner** flashed with [FM-DX-Tuner firmware](https://github.com/kkonradpl/FM-DX-Tuner)
- Lyrion Music Server 8.x

---

## Setup

### 1. Find your device names

```bash
# Serial control port (usually ttyACM0)
ls /dev/ttyACM*

# ALSA capture device — the tuner is a recording device, not a playback device
arecord -l
```

The output of `arecord -l` will look something like:
```
card 2: Tuner [FM-DX Tuner], device 0: USB Audio [USB Audio]
```

Your ALSA device string is `hw:CARD=Tuner,DEV=0`.

Verify audio is working:
```bash
arecord -D hw:CARD=Tuner,DEV=0 -f S16_LE -r 48000 -c 2 - | aplay -
```

### 2. Install the LMS plugin

```bash
cp -r Plugin/TEFRadio /config/cache/InstalledPlugins/Plugins/
# Restart LMS
```

Common LMS plugin paths:
- Docker (lmscommunity image): `/config/cache/InstalledPlugins/Plugins/`
- Debian package: `/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/`
- Manual install: `~/.squeezeboxserver/cache/InstalledPlugins/Plugins/`

### 3. Configure via the LMS web UI

Go to **Settings → Plugins → TEF FM Radio** and set:

| Setting | Example | How to find it |
|---------|---------|----------------|
| Serial Port | `/dev/ttyACM0` | `ls /dev/ttyACM*` |
| ALSA Audio Device | `hw:CARD=Tuner,DEV=0` | `arecord -l` |
| MP3 Bitrate | `192k` | — |
| Station Presets | `DR P1\|90.8` | one per line |

### 4. Play

The plugin appears under **My Apps → TEF FM Radio** in the LMS web UI and on Squeezebox hardware under **Radios → TEF FM Radio**. Select a station and it starts instantly.

---

## Station Presets

The settings page accepts one station per line in `Name|Frequency (MHz)` format:

```
DR P1|90.8
DR P2|96.5
DR P3|97.0
DR P4 Kbh|93.9
DR P5|103.9
Radio 100|100.0
```

These are also the defaults shipped with the plugin.

---

## Optional: fm-tef-daemon (Icecast streaming)

The `daemon/` directory contains `fm-tef-daemon.py`, an alternative approach that
pushes audio to an **Icecast** server instead of piping directly into LMS. This is
useful if you want multiple listeners, recording, or remote access without LMS.

See the [daemon README](daemon/) for setup instructions.

---

## Differences from the RTL-SDR version

| | Lyrion FM Radio (RTL-SDR) | Lyrion TEF Radio (this) |
|--|--|--|
| Demodulation | NGSoftFM (software) | TEF668X hardware |
| Audio path | Icecast HTTP stream | Direct pipe → LMS |
| External servers | Icecast required | None |
| Tuning | Restarts NGSoftFM | Single serial command |
| Dependencies | softfm, Icecast | ffmpeg only |
