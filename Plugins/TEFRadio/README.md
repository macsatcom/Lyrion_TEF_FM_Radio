# TEF FM Radio — Lyrion Music Server Plugin

Play FM radio from a **TEF668X USB tuner** directly in [Lyrion Music Server](https://lyrion.org/) (formerly Logitech Media Server / Squeezebox Server).

Stations appear alongside your music library and stream instantly to any Squeezebox hardware or squeezelite software player on your network.

---

## Background — SharkPlay and the idea of a "radio input" plugin

This plugin is a spiritual successor to [SharkPlay](https://forums.slimdevices.com/forum/user-forums/3rd-party-software/101473-sharkplay-plugin-play-radio-from-a-hardware-tuner), a beloved community plugin that let you route a physical radio tuner (or any line-level audio source) into Lyrion by capturing the signal on the server and streaming it to your players. SharkPlay was widely used for FM, DAB and even cassette decks — anything with an audio output you could feed into the server's sound card.

TEF FM Radio does the same thing, but with a **TEF668X-based USB tuner**:

- The tuner is a self-contained USB device that does FM demodulation entirely in hardware and presents two interfaces: a serial control port for tuning commands and a USB audio device for the demodulated stereo output.
- No sound card input is needed. No SDR software stack. No Icecast server.
- Changing stations is a single serial command — the hardware switches in milliseconds.

If you used SharkPlay and want the same "radio as a source" experience with modern, cheap FM DX hardware, this is the plugin for you.

---

## How it works

```
TEF668X USB tuner
      │
      ├── /dev/ttyACM0  (serial control)
      │         └── tef-stream.pl  →  "T90800\n"  (tune to 90.8 MHz)
      │
      └── ALSA capture device  (USB audio out)
                └── ffmpeg  (ALSA → MP3 encode)
                        └── stdout pipe
                                └── LMS plugin  →  Squeezebox / squeezelite
```

When you select a station in Lyrion:

1. `ProtocolHandler.pm` spawns `tef-stream.pl`
2. `tef-stream.pl` sends a tune command over the serial port, then `exec()`s into ffmpeg
3. ffmpeg reads PCM audio from the USB capture device and encodes it as MP3 on stdout
4. LMS reads MP3 frames from the pipe and streams them to your player(s)

No separate server process, no HTTP relay, no Icecast — the audio pipeline lives entirely inside LMS.

---

## Requirements

| Requirement | Notes |
|---|---|
| Lyrion Music Server 8.x | Tested on lmscommunity Docker image |
| ffmpeg with libmp3lame | Must be available in `$PATH` |
| TEF668X USB tuner | Flashed with [FM-DX-Tuner](https://github.com/kkonradpl/FM-DX-Tuner) headless firmware ([units available on Discord marketplace](https://discord.com/channels/1053804249651359765/1300155791294070826)) |
| Perl 5 | Already present in LMS — no extra modules needed |

Python is **not** required. The plugin is written entirely in Perl (the same language as LMS itself) and works inside the lmscommunity Docker container without any modifications to the image.

---

## Installation

### Option A — via LMS plugin repository (recommended)

1. In the LMS web UI go to **Settings → Plugin Settings → Additional Repositories**
2. Add this URL and save:
   ```
   https://raw.githubusercontent.com/macsatcom/Lyrion_TEF_FM_Radio/main/repo.xml
   ```
3. Go to **Settings → Plugins**, find **TEF FM/AM Radio** and click **Install**
4. Restart LMS when prompted

LMS downloads and installs the zip automatically. Skip to [Configure the plugin](#3-configure-the-plugin) below.

---

### Option B — manual installation

### 1. Find your device names

Plug in the TEF tuner, then on the **LMS host** (or inside the container if using Docker):

```bash
# Serial control port — usually ttyACM0
ls /dev/ttyACM*

# ALSA capture device — the tuner is a recording device, not a playback device
arecord -l
```

Example `arecord -l` output:
```
card 2: Tuner [FM-DX Tuner], device 0: USB Audio [USB Audio]
```

Your ALSA device string is `hw:CARD=Tuner,DEV=0`.

Verify audio works before touching the plugin:
```bash
arecord -D hw:CARD=Tuner,DEV=0 -f S16_LE -r 48000 -c 2 - | aplay -
```

You should hear the radio. Tune to a strong station first if it is silent.

### 2. Install the plugin manually

Copy the `TEFRadio/` directory into your LMS plugin folder and restart LMS.

| Setup | Plugin path |
|---|---|
| Docker (lmscommunity) | `/config/cache/InstalledPlugins/Plugins/` |
| Debian / Ubuntu package | `/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/` |
| Manual install | `~/.squeezeboxserver/cache/InstalledPlugins/Plugins/` |

```bash
cp -r TEFRadio /config/cache/InstalledPlugins/Plugins/
```

Then restart LMS.

### 3. Docker — pass through the USB devices

The lmscommunity container needs access to both USB interfaces. Add them to your `docker-compose.yml`:

```yaml
services:
  lms:
    image: lmscommunity/lyrionmusicserver:latest
    devices:
      - /dev/ttyACM0:/dev/ttyACM0   # serial control port
      - /dev/snd:/dev/snd            # ALSA (includes the TEF USB audio device)
    group_add:
      - audio
      - dialout
    ...
```

`dialout` is needed for serial port access; `audio` for ALSA.

### 4. Configure the plugin

Go to **Settings → Plugins → TEF FM Radio** in the LMS web UI:

| Setting | Example | Description |
|---|---|---|
| Serial Port | `/dev/ttyACM0` | USB serial control port (`ls /dev/ttyACM*`) |
| ALSA Audio Device | `hw:CARD=Tuner,DEV=0` | USB audio capture device (`arecord -l`) |
| MP3 Bitrate | `192k` | Quality of the audio stream to players |
| Station Presets | `DR P1\|90.8` | One station per line, `Name\|MHz` format |

### 5. Play

The plugin appears under **My Apps → TEF FM Radio** in the LMS web UI, and under **Radios → TEF FM Radio** on Squeezebox hardware. Select a station and playback starts within a second.

---

## Station presets

One station per line in the settings text box:

```
DR P1|90.8
DR P2|96.5
DR P3|97.0
DR P4 Kbh|93.9
DR P5|103.9
Radio 100|100.0
Hits FM|95.9
Radio Soft|96.1
```

Frequencies must be in the 87.5–108.0 MHz FM band. Frequencies outside this range are silently ignored when saving.

---

## Troubleshooting

**No audio / silent stream**

- Check that `arecord -l` shows the tuner on the LMS host.
- Verify `arecord -D hw:CARD=Tuner,DEV=0 -f S16_LE -r 48000 -c 2 - | aplay -` works outside LMS.
- Make sure `ffmpeg` is in `$PATH` inside the container (`which ffmpeg`).

**"Could not start TEF radio stream" error in LMS**

- Check the serial port path in settings (`ls /dev/ttyACM*`).
- Ensure the LMS process (or container) has permission to open the serial device (`ls -l /dev/ttyACM0` — group should be `dialout`).

**Docker: device not found**

- Confirm the `devices:` and `group_add:` entries are in your compose file.
- After changing compose, do a full `docker compose down && docker compose up -d`.

---

## Architecture notes

`tef-stream.pl` is intentionally minimal — it exists only to send the tune command and then get out of the way. The `$^X` variable (Perl's own binary path) is used to spawn it, so the helper script always runs under the same Perl interpreter as LMS itself, with no dependency on a system `perl` in `$PATH`.

The plugin registers the `tefradio://` URL scheme. Station URLs are of the form `tefradio://90.8` (MHz). LMS treats these as live streams (no seeking, no duration).
