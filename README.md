# vn-chill

A toggle script for entering/exiting "Ren'Py chill mode" on macOS — optimizing your system for lap/chest comfort while reading visual novels.

## Purpose

This script toggles between normal and low-power states by:
- Closing noisy/resource-heavy apps (configurable)
- Enabling Low Power Mode
- Reducing display refresh rate to 60 Hz at a lower resolution
- Storing previous settings in a lockfile for easy restoration

Running the script a second time restores your original settings.

## Requirements

- **macOS** (tested on systems with `pmset` and AppleScript support)
- **[displayplacer](https://github.com/jakehilborn/displayplacer)** — Install via:
  ```sh
  brew install displayplacer
  ```
- **sudo access** — Required for `pmset` to toggle Low Power Mode

## Configuration

Before first use, edit `vn-chill.sh` and configure:

1. **DISPLAY_ID** — Run `displayplacer list` and copy your built-in display's persistent ID
2. **CLOSE_APPS** — Add/remove app names to quit when entering chill mode
3. **CHILL_RES / CHILL_HZ / CHILL_COLOR_DEPTH / CHILL_SCALING** — Adjust display settings as desired

## Usage

```sh
./vn-chill.sh
```

- **First run**: Enters chill mode, creates `~/.vn-chill.lock`
- **Second run**: Restores previous settings, removes lockfile

## How It Works

1. **Enter mode**: Captures current display settings and Low Power Mode state, quits configured apps, applies chill settings, writes lockfile
2. **Exit mode**: Reads lockfile, restores original display and power settings, removes lockfile

Apps are asked to quit gracefully via AppleScript; after a 4-second grace period, they're force-killed if still running.

---

⚠️ **Warning**: This is vibe-coded slop I threw together while trying to set up to play games. Use at your own risk.
