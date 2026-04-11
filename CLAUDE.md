# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a multi-component FM DXing (distant reception) platform. Four distinct components:

- **FM-DX Webserver** (`fm-dx-webserver/`) — Node.js web interface for remote radio control (port 8080)
- **FM-DX Tuner** (`FM-DX-Tuner/`) — Arduino/C++ microcontroller firmware for NXP radio tuners
- **XDR-GTK** (`xdr-gtk/`) — C/GTK+ 3 desktop application for local tuner control
- **xdrd** (`xdrd/`) — C daemon bridging serial/USB hardware to TCP (port 7373)

## Commands

### FM-DX Webserver (Node.js)
```bash
npm install          # Install dependencies
npm run webserver    # Start server
npm run debug        # Start with debug logging
npm run debug_full   # Full debug (includes FFmpeg)
```

### XDR-GTK (C/CMake)
```bash
cd xdr-gtk
cmake -B build/
cmake --build build/
sudo make -C build/ install
```

### FM-DX Tuner (Arduino/C++)
Flashed via Arduino IDE. Supports AVR (ATmega328P), ESP32, and STM32 (STM32F072) targets.
- STM32 additional dependencies: STM32duino board package + TinyUSB library (install manually)
- First-time STM32 flash: short BOOT to 3.3V, plug USB, use DFU method in Arduino IDE

Configuration is done entirely via header files before compilation:
- `Config.hpp` — tuner driver selection, I2C clock, serial speed, peripheral enables
- `ConfigTEF668X.hpp` / `ConfigSAF7730.hpp` / `ConfigSAF775X.hpp` — tuner-specific settings
- `presets/tef-headless/` — predefined config for STM32 headless USB tuner

### xdrd (C/Make)
```bash
cd xdrd
make                 # Build for Linux
make windows         # Cross-compile for Windows
make install         # Install to /usr/bin/xdrd
```

## Architecture

```
[FM-DX Tuner firmware] → Hardware (USB/Serial)
                              └── xdrd (TCP :7373) — hardware bridge, multi-user, auth
                                      ├── FM-DX Webserver (HTTP :8080 / WebSocket) — web UI + plugin system
                                      │       └── Browser clients
                                      └── XDR-GTK — native desktop UI
```

**xdrd** handles all serial communication and multiplexes multiple clients. The protocol is single-char command-based (defined in `xdr-protocol.h`). Authentication uses a salt-based challenge via OpenSSL crypto.

**FM-DX Webserver** key files:
- `index.js` — entry point
- `server/index.js` — Express + WebSocket setup, plugin loader
- `server/endpoints.js` — HTTP routes (tune, scan, config)
- `server/datahandler.js` — RDS parsing via FFI (koffi → librdsparser C library)
- `server/server_config.js` — reads/writes `config.json`
- `server/stream/` — FFmpeg subprocess + 3LAS low-latency audio streaming
- `web/index.ejs` — main UI template
- `plugins/` — optional server modules loaded by convention (`*_server.js`)

**XDR-GTK** (`src/`) is ~45 C files. Key ones: `main.c` (GTK init), `tuner-conn.c` (TCP to xdrd), `tuner.c` (hardware logic), `conf.c` (config persistence), `antpatt.c` (antenna pattern visualization). `librdsparser/` is a git submodule for RDS decoding, statically linked.

## Configuration

`config.json` in the webserver root is auto-generated on first run. It controls: HTTP port/IP, xdrd connection (TCP address or serial path), audio device, FFmpeg settings, antenna setup, plugin list, device type (`tef`, `xdr`, `sdr`, etc.), and tunnel/relay settings.

## Key Dependencies

| Component    | Notable deps |
|--------------|-------------|
| Webserver    | `express` 5, `ws`, `serialport`, `ffmpeg-static`, `koffi` (FFI), `ejs` |
| FM-DX Tuner  | Arduino IDE, STM32duino (STM32 target), TinyUSB (STM32 target) |
| XDR-GTK      | GTK+ 3, glib-compile-resources, CMake ≥ 3.x |
| xdrd         | GCC, pthreads, OpenSSL (`-lcrypto`) |

The webserver calls into the C `librdsparser` library at runtime via `koffi` FFI — the `.so`/`.dll` must be present or compiled.
