#!/usr/bin/env bash
set -euo pipefail

# vn-chill.sh — toggle a "Ren'Py chill mode" for lap/chest comfort.
# - Quits select apps (graceful -> kill)
# - Enables Low Power Mode
# - Forces built-in display to 60 Hz using displayplacer
# - Creates lockfile with previous settings to restore on next run

###############
# USER CONFIG #
###############

# Apps/processes to close when entering chill mode.
# Use the *app name* as it appears in Activity Monitor (and usually as the .app name).
# Examples: "Discord", "Google Chrome", "Steam"
CLOSE_APPS=(
    "Discord"
)

# How long to wait (seconds) after asking apps to quit before force-killing.
QUIT_GRACE_SECONDS=4

# Lockfile location
LOCKFILE="${HOME}/.vn-chill.lock"

# Your built-in display persistent id (from displayplacer list)
DISPLAY_ID="37D8832A-2D66-02CA-B9F7-8F30A301B230"

# The "chill" display mode you want
CHILL_RES="1280x800"
CHILL_HZ="60"
CHILL_COLOR_DEPTH="8"
CHILL_SCALING="on"

#################
# DEPENDENCIES  #
#################

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: required command not found: $1" >&2
        exit 1
    }
}

need_cmd displayplacer
need_cmd pmset
need_cmd osascript

#################
# HELPER FUNCS  #
#################

timestamp() { date +"%Y-%m-%dT%H:%M:%S%z"; }

log() { echo "[$(timestamp)] $*"; }

# Returns 0 if app is running, 1 otherwise
app_running() {
    local app="$1"
    pgrep -x "$app" >/dev/null 2>&1
}

# Ask app to quit gracefully via AppleScript, then kill if needed
quit_app() {
    local app="$1"
    if app_running "$app"; then
        log "Requesting quit: $app"
        # Graceful quit request (won't error if app doesn't support it cleanly)
        osascript -e "tell application \"$app\" to quit" >/dev/null 2>&1 || true

        local waited=0
        while app_running "$app" && [[ $waited -lt $QUIT_GRACE_SECONDS ]]; do
            sleep 1
            waited=$((waited + 1))
        done

        if app_running "$app"; then
            log "Force killing: $app"
            pkill -x "$app" >/dev/null 2>&1 || true
        else
            log "Exited cleanly: $app"
        fi
    else
        log "Not running (skip): $app"
    fi
}

# Grab current displayplacer mode line for this display.
# We store enough to restore exactly (res/hz/color_depth/scaling/origin)
get_current_display_mode() {
  # Find the "<-- current mode" line inside the block for DISPLAY_ID
  local line
  line="$(displayplacer list | awk -v id="$DISPLAY_ID" '
    $0 ~ "Persistent screen id: "id {inblock=1}
    inblock && $0 ~ "<-- current mode" {print; exit}
  ' | tr -d "\r")"

  if [[ -z "${line}" ]]; then
    echo "Error: could not find current mode line for display id ${DISPLAY_ID}" >&2
    exit 1
  fi

  # Extract key:value tokens robustly
  local res hz depth scaling
  res="$(echo "$line" | grep -oE 'res:[0-9]+x[0-9]+' | head -n1 | cut -d: -f2)"
  hz="$(echo "$line" | grep -oE 'hz:[0-9]+'           | head -n1 | cut -d: -f2)"
  depth="$(echo "$line" | grep -oE 'color_depth:[0-9]+' | head -n1 | cut -d: -f2)"
  scaling="$(echo "$line" | grep -oE 'scaling:(on|off)'  | head -n1 | cut -d: -f2)"

  if [[ -z "$res" || -z "$hz" || -z "$depth" || -z "$scaling" ]]; then
    echo "Error: failed to parse current mode fields from: $line" >&2
    echo "Parsed: res='$res' hz='$hz' depth='$depth' scaling='$scaling'" >&2
    exit 1
  fi

  echo "${res}|${hz}|${depth}|${scaling}"
}


get_low_power_mode_state() {
    # On macOS, "pmset -g" includes lowpowermode as 0/1.
    # We'll read the "Currently in use:" block for accuracy.
    pmset -g | awk '
    $0 ~ "Currently in use:" {inuse=1; next}
    inuse && $1=="lowpowermode" {print $2; exit}
  ' | tr -d '\r'
}

set_low_power_mode() {
    local val="$1" # 0 or 1
    log "Setting Low Power Mode -> ${val}"
    sudo pmset -a lowpowermode "$val"
}

set_display_mode() {
    local res="$1" hz="$2" depth="$3" scaling="$4"
    log "Setting display -> res:${res} hz:${hz} depth:${depth} scaling:${scaling}"
    displayplacer "id:${DISPLAY_ID} res:${res} hz:${hz} color_depth:${depth} scaling:${scaling}"
}

write_lockfile() {
    local prev_res="$1" prev_hz="$2" prev_depth="$3" prev_scaling="$4" prev_lpm="$5"

    cat >"$LOCKFILE" <<EOF
# vn-chill lockfile (do not edit unless you know what you're doing)
DISPLAY_ID=${DISPLAY_ID}
PREV_RES=${prev_res}
PREV_HZ=${prev_hz}
PREV_COLOR_DEPTH=${prev_depth}
PREV_SCALING=${prev_scaling}
PREV_LOWPOWERMODE=${prev_lpm}
CREATED_AT=$(timestamp)
EOF

    chmod 600 "$LOCKFILE" || true
}

read_lockfile() {
    # shellcheck disable=SC1090
    source "$LOCKFILE"
}

enter_chill_mode() {
    log "Entering VN Chill Mode"

    # Quit noisy apps first (reduce load before we flip power/display)
    for app in "${CLOSE_APPS[@]}"; do
        quit_app "$app"
    done

    # Capture current states for restore
    local mode prev_res prev_hz prev_depth prev_scaling prev_lpm
    mode="$(get_current_display_mode)"
    prev_res="${mode%%|*}"
    mode="${mode#*|}"
    prev_hz="${mode%%|*}"
    mode="${mode#*|}"
    prev_depth="${mode%%|*}"
    prev_scaling="${mode#*|}"

    prev_lpm="$(get_low_power_mode_state)"
    if [[ -z "$prev_lpm" ]]; then
        prev_lpm="0"
    fi

    log "Current display mode: ${prev_res} @ ${prev_hz}Hz (depth ${prev_depth}, scaling ${prev_scaling})"
    log "Current Low Power Mode: ${prev_lpm}"

    # Apply chill settings
    set_low_power_mode 1
    set_display_mode "$CHILL_RES" "$CHILL_HZ" "$CHILL_COLOR_DEPTH" "$CHILL_SCALING"

    # Save restore info
    write_lockfile "$prev_res" "$prev_hz" "$prev_depth" "$prev_scaling" "$prev_lpm"

    log "Chill mode enabled. Lockfile: $LOCKFILE"
}

exit_chill_mode() {
    log "Exiting VN Chill Mode (restoring prior settings)"

    read_lockfile

    # Restore display first (often nicer visually), then power mode
    set_display_mode "$PREV_RES" "$PREV_HZ" "$PREV_COLOR_DEPTH" "$PREV_SCALING"
    set_low_power_mode "${PREV_LOWPOWERMODE:-0}"

    rm -f "$LOCKFILE"
    log "Restored. Lockfile removed."
}

############
# MAIN     #
############

if [[ -f "$LOCKFILE" ]]; then
    exit_chill_mode
else
    enter_chill_mode
fi
