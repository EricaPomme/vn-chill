# vn-chill

A toggle script for entering/exiting "Ren'Py chill mode" on macOS — optimizing your system for temperature control and power management while reading visual novels.

## Purpose

This script toggles between normal and low-power states by:
- Closing noisy/resource-heavy apps (configurable)
- Enabling Low Power Mode
- Reducing display refresh rate to 60 Hz at a lower resolution
- Storing previous settings in a lockfile for easy restoration

Running the script a second time restores your original settings.

## Requirements

- **macOS**
- **sudo access** — Required for `pmset` to toggle Low Power Mode

## Configuration

Before first use, edit `vn-chill.swift` and configure:

1. **Config.appsToQuit** — Add/remove app bundle identifiers to quit when entering chill mode (e.g. `com.apple.Safari`)
2. **Config.chillWidth / Config.chillHeight / Config.chillRefreshHz** — Adjust display settings as desired
3. **Config.quitGraceSeconds** — Delay before force-terminating apps

## Usage

Compile and run:

```sh
swiftc vn-chill.swift -framework AppKit -framework CoreGraphics -o vn-chill
./vn-chill
```

- **First run**: Enters chill mode, creates `~/.vn-chill.json`
- **Second run**: Restores previous settings, removes lockfile

## How It Works

1. **Enter mode**: Finds the built-in display, captures current mode + Low Power Mode state, quits configured apps, applies chill settings, writes lockfile
2. **Exit mode**: Reads lockfile, restores original display and power settings, removes lockfile

Apps are asked to quit gracefully through `NSRunningApplication`; after the grace period, they are force-terminated if still running.

---

⚠️ **Warning**: This is vibe-coded slop I threw together while trying to set up to play games. Use at your own risk.
