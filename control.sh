#!/bin/bash
# Minimal window/launch helper for the Apple Music bar plugin. Everything
# else (MPRIS metadata, playback control, theming) comes for free from
# Chromium's MPRIS bridge and Omarchy's system-wide browser theme policy, so
# this script only has to know how to find or start the dedicated Chromium
# window, how to show and hide it, and how to shut it down on removal.
set -euo pipefail

APPLE_MUSIC_BASE_URL="https://music.apple.com"
PLUGIN_ID="io.github.leandro-3rne.apple-music"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/leandro-3rne-apple-music"
PROFILE_DIR="$DATA_DIR/chromium"
STOREFRONT_FILE="$DATA_DIR/storefront"
LAST_PLAYED_FILE="$DATA_DIR/last-played"
# Keep enough of the original cover for the large, high-resolution player art.
ART_MAX_BYTES=$((8 * 1024 * 1024))
SPECIAL_WORKSPACE="special:Music"
PREVIOUS_SPECIAL_WORKSPACE="special:Apple Music"
LEGACY_SPECIAL_WORKSPACE="special:AM"
# Resolved once at startup, while the plugin folder is still known to be
# there: quit_window checks this path later, after removal may have taken
# the folder away.
PLUGIN_DIR="$(dirname -- "${BASH_SOURCE[0]}")"
WINDOW_SWITCHER_DIR="$HOME/.config/omarchy/plugins/io.github.leandro-3rne.window-switcher"

# Apple Music can leave an authenticated web session in the 90-second preview
# mode when the storefront inferred for the regionless URL does not match the
# Apple Account. A two-letter storefront can therefore be pinned outside the
# repository, alongside the browser profile. The environment override is
# useful for one-off launches; the file is the persistent plugin setting.
apple_music_url() {
  local storefront=${APPLE_MUSIC_STOREFRONT:-}
  if [[ -z $storefront && -f $STOREFRONT_FILE && ! -L $STOREFRONT_FILE ]]; then
    IFS= read -r storefront <"$STOREFRONT_FILE" || true
  fi
  storefront=${storefront,,}
  if [[ $storefront =~ ^[a-z]{2}$ ]]; then
    printf '%s/%s/home\n' "$APPLE_MUSIC_BASE_URL" "$storefront"
  else
    printf '%s/home\n' "$APPLE_MUSIC_BASE_URL"
  fi
}

set_storefront() {
  local storefront=${1,,} temp
  [[ $storefront =~ ^[a-z]{2}$ ]] || {
    echo "storefront must be a two-letter country code (for example: ch)" >&2
    exit 2
  }
  if [[ -L $DATA_DIR || -L $STOREFRONT_FILE ]]; then
    echo "refusing to write storefront through a symlink" >&2
    exit 1
  fi
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  temp=$(mktemp "$DATA_DIR/.storefront.XXXXXX")
  chmod 600 "$temp"
  printf '%s\n' "$storefront" >"$temp"
  mv -f -- "$temp" "$STOREFRONT_FILE"
}

# Chromium's app window does not reliably complete Apple's first-time sign-in:
# the page can look authenticated without ever receiving a persistent Music
# token. Once that token exists, the app window reuses it normally. Inspect
# only the cookie metadata, never the encrypted token value.
has_persistent_session() {
  local cookies="$PROFILE_DIR/Default/Cookies"
  [[ -f $cookies ]] || return 1

  python3 - "$cookies" <<'PY'
import sqlite3
import sys
import time

try:
    database = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    minimum_expiry = int((time.time() + 11_644_473_600) * 1_000_000)
    authenticated = database.execute(
        """
        SELECT 1 FROM cookies
        WHERE name = 'media-user-token'
          AND is_persistent = 1
          AND expires_utc > ?
        LIMIT 1
        """,
        (minimum_expiry,),
    ).fetchone()
except (OSError, sqlite3.Error):
    raise SystemExit(1)

raise SystemExit(0 if authenticated else 1)
PY
}

# --class is ignored by Chromium in --app mode: the window reports a
# generic class like "chrome-music.apple.com__-Default" regardless, and
# that generic class isn't unique if another Apple Music plugin using the
# same URL is also installed. Identify our window by process instead:
# every process launched with our --user-data-dir shares that flag
# (including Chromium's zygote/gpu/renderer children), so the one *without*
# a --type= argument is the top-level browser process that owns the window.
browser_pid() {
  local candidate
  for candidate in $(pgrep -f -- "--user-data-dir=$PROFILE_DIR" 2>/dev/null); do
    if ! tr '\0' '\n' <"/proc/$candidate/cmdline" 2>/dev/null | grep -q '^--type='; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Chromium leaves Singleton* symlinks behind when it is killed or crashes.
# Remove them only after confirming that our dedicated browser is gone and
# that the previous singleton socket no longer exists. This preserves the
# signed-in profile while preventing a stale lock from blocking the next
# launch.
clear_stale_profile_locks() {
  local socket_target singleton listening_sockets

  if browser_pid >/dev/null 2>&1; then
    return 0
  fi

  socket_target=$(readlink -- "$PROFILE_DIR/SingletonSocket" 2>/dev/null || true)
  if [[ -n $socket_target && $socket_target != /* ]]; then
    socket_target="$PROFILE_DIR/$socket_target"
  fi
  if [[ -n $socket_target && -S $socket_target ]]; then
    # A stale Unix socket remains a socket file after Chromium is killed or
    # crashes. Merely testing -S therefore mistakes stale locks for a live
    # browser and blocks every future launch. Ask the kernel whether this
    # exact path is currently listening instead.
    command -v ss >/dev/null 2>&1 || {
      echo "refusing to clear Apple Music profile locks: cannot verify Chromium socket" >&2
      return 1
    }
    listening_sockets=$(ss -lxH 2>/dev/null) || {
      echo "refusing to clear Apple Music profile locks: cannot inspect Chromium socket" >&2
      return 1
    }
    if awk -v target="$socket_target" '$2 == "LISTEN" && $5 == target { found=1 } END { exit(found ? 0 : 1) }' <<<"$listening_sockets"; then
      echo "refusing to clear Apple Music profile locks: Chromium socket is active" >&2
      return 1
    fi
  fi

  for singleton in \
    "$PROFILE_DIR/SingletonLock" \
    "$PROFILE_DIR/SingletonCookie" \
    "$PROFILE_DIR/SingletonSocket"; do
    [[ -L $singleton ]] || continue
    unlink -- "$singleton" || {
      echo "could not clear stale Apple Music Chromium lock: $singleton" >&2
      return 1
    }
  done
}

# Emits the window's identity, workspace, and real visibility. A special
# workspace is visible only while a monitor is presenting it; its name alone
# is therefore not enough to decide whether the bar should say Open or Hide.
state() {
  local pid clients monitors last_source="" last_address=""
  pid=$(browser_pid || true)
  pid=${pid:-0}
  if [[ -f $LAST_PLAYED_FILE && ! -L $LAST_PLAYED_FILE ]]; then
    read -r last_source last_address <"$LAST_PLAYED_FILE" || true
  fi
  [[ $last_source == apple || $last_source == youtube ]] || last_source=""
  [[ $last_address =~ ^0x[0-9a-fA-F]+$ ]] || last_address=""
  clients=$(hyprctl -j clients 2>/dev/null) || clients="[]"
  monitors=$(hyprctl -j monitors 2>/dev/null) || monitors="[]"
  jq -cn --argjson pid "$pid" --argjson clients "$clients" --argjson monitors "$monitors" \
    --arg lastSource "$last_source" --arg lastAddress "$last_address" '
    (first($clients[] | select(.pid == $pid)) // null) as $c |
    ([$clients[] | select((.title // "" | test("YouTube"; "i"))
       or (.class // "" | test("youtube"; "i"))
       or (.initialClass // "" | test("youtube"; "i")))]
       | sort_by(if (.focusHistoryID // -1) < 0 then 999999 else .focusHistoryID end)) as $youtubeWindows |
    ($youtubeWindows[0]) as $yt |
    ($c.workspace.name // "") as $workspace |
    ($yt.workspace.name // "") as $youtubeWorkspace |
    {
      open: ($c != null),
      address: ($c.address // ""),
      pid: $pid,
      lastPlayedSource: $lastSource,
      lastYoutubeAddress: $lastAddress,
      workspace: $workspace,
      appleHistory: (if $c == null then 999999 else ($c.focusHistoryID // 999999) end),
      youtubeAddress: ($yt.address // ""),
      youtubePid: ($yt.pid // 0),
      youtubePids: [$youtubeWindows[] | .pid],
      youtubeWindows: [$youtubeWindows[] | . as $yw | {
        address, pid, title, workspace: .workspace.name,
        visible: any($monitors[];
          .activeWorkspace.name == $yw.workspace.name or .specialWorkspace.name == $yw.workspace.name)
      }],
      youtubeWorkspace: $youtubeWorkspace,
      youtubeHistory: (if $yt == null then 999999 else ($yt.focusHistoryID // 999999) end),
      youtubeVisible: ($yt != null and any($monitors[];
        .activeWorkspace.name == $youtubeWorkspace or .specialWorkspace.name == $youtubeWorkspace)),
      visible: (
        $c != null and any($monitors[];
          .activeWorkspace.name == $workspace or .specialWorkspace.name == $workspace
        )
      )
    }
  '
}

remember_playback() {
  local source=${1:-} address=${2:-} youtube_address=${3:-} temp
  [[ $source == apple || $source == youtube ]] || return 2
  [[ $address =~ ^0x[0-9a-fA-F]+$ ]] || return 2
  [[ $youtube_address =~ ^0x[0-9a-fA-F]+$ || -z $youtube_address ]] || return 2
  if [[ $source == youtube ]]; then youtube_address=$address; fi
  [[ ! -L $DATA_DIR && ! -L $LAST_PLAYED_FILE ]] || return 1
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  temp=$(mktemp "$DATA_DIR/.last-played.XXXXXX")
  chmod 600 "$temp"
  printf '%s %s\n' "$source" "$youtube_address" >"$temp"
  mv -f -- "$temp" "$LAST_PLAYED_FILE"
}

launch() {
  local launch_url
  command -v chromium >/dev/null 2>&1 || { echo "chromium not found" >&2; exit 1; }
  # The profile holds the signed-in session, so it is only ever created at the
  # real location — never through a link standing in for it.
  if [[ -L $DATA_DIR ]]; then
    echo "refusing to launch: $DATA_DIR is a symlink" >&2
    exit 1
  fi
  mkdir -p "$PROFILE_DIR"
  clear_stale_profile_locks
  launch_url=$(apple_music_url)
  if has_persistent_session; then
    exec uwsm-app -- chromium \
      --user-data-dir="$PROFILE_DIR" \
      --app="$launch_url" \
      --no-first-run
  fi

  # Use a regular browser window only for initial authentication. After the
  # user signs in and closes it, the next launch returns to app mode.
  exec uwsm-app -- chromium \
    --user-data-dir="$PROFILE_DIR" \
    --no-first-run \
    "$launch_url"
}

# Shows and focuses the window. Apple Music is never revealed by opening its
# parking special workspace. A window already placed on a normal workspace is
# kept there and focused, which switches to its existing workspace instead of
# moving it under the user. Only a window parked on special:Apple Music (or the
# legacy special:AM) is moved into the currently focused workspace; a visible
# or empty Scratchpad takes precedence, and a focused group is joined in that
# target when it is a real workspace target.
# Classic dispatch strings ("movetoworkspace ...") are not reliably honored
# by this Hyprland build, whether issued via the hyprctl CLI or Quickshell's
# Hyprland.dispatch(); hl.dsp.* via `hyprctl eval` is the mechanism that
# does work, so this always goes through eval, even when the window is
# already visible — moving it onto the workspace it is already on is a
# harmless no-op, and it keeps this one code path in charge of "show".
#
# hl.dsp.focus() warps the pointer to the target window as a side effect, so
# this saves the cursor position first and restores it after — otherwise
# every right-click yanks your mouse over to wherever the window ends up.
show_window() {
  local address=$1 target_address=${2:-} target_expr='hl.get_active_window()'
  local empty_scratchpad_state empty_scratchpad=false active_workspace_id scratchpad_visible=false
  local source_window_json source_workspace_name source_workspace_id target_fullscreen_workspace_id
  [[ $address =~ ^0x[0-9a-fA-F]+$ ]] || { echo "invalid address: $address" >&2; exit 2; }
  if [[ -n $target_address ]]; then
    [[ $target_address =~ ^0x[0-9a-fA-F]+$ ]] || { echo "invalid target address: $target_address" >&2; exit 2; }
    target_expr="hl.get_window(\"address:$target_address\")"
  fi
  empty_scratchpad_state=$(omarchy-shell shell call io.github.leandro-3rne.window-switcher isScratchpadEmpty '{}' 2>/dev/null || true)
  [[ $empty_scratchpad_state == true ]] && empty_scratchpad=true
  # Read the normal active workspace directly from Hyprland. The Lua helper's
  # active-workspace object can retain a just-hidden special workspace for one
  # dispatch cycle, which must never make the Apple Music parking workspace a
  # show target.
  active_workspace_id=$(hyprctl -j activeworkspace 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)
  [[ $active_workspace_id =~ ^[0-9]+$ ]] || active_workspace_id=""
  if hyprctl -j monitors 2>/dev/null | jq -e 'any(.[]; .specialWorkspace.name == "special:scratchpad")' >/dev/null 2>&1; then
    scratchpad_visible=true
  fi
  source_window_json=$(hyprctl -j clients 2>/dev/null | jq -c --arg address "$address" '
    first(.[] | select(.address == $address)) // {}
  ' 2>/dev/null || printf '{}')
  source_workspace_name=$(jq -r '.workspace.name // ""' <<<"$source_window_json")
  source_workspace_id=$(jq -r '.workspace.id // empty' <<<"$source_window_json")
  if [[ $source_workspace_name == "$SPECIAL_WORKSPACE" || $source_workspace_name == "$PREVIOUS_SPECIAL_WORKSPACE" || $source_workspace_name == "$LEGACY_SPECIAL_WORKSPACE" ]]; then
    if [[ $empty_scratchpad != true && $scratchpad_visible != true ]]; then
      target_fullscreen_workspace_id=$active_workspace_id
    else
      target_fullscreen_workspace_id=""
    fi
  else
    target_fullscreen_workspace_id=$source_workspace_id
  fi
  if [[ $target_fullscreen_workspace_id =~ ^[1-9][0-9]*$ ]]; then
    bash "$WINDOW_SWITCHER_DIR/unfullscreen-workspace.sh" "$target_fullscreen_workspace_id" || true
  fi
  # A workspace move is group-aware. Detach Apple Music first only when it is
  # parked on the Apple Music special workspace; focusing an already-placed
  # normal-workspace window must preserve its existing group.
  hyprctl eval "
    local w = hl.get_window(\"address:$address\")
    if w and w.group and w.workspace and (w.workspace.name == \"$SPECIAL_WORKSPACE\" or w.workspace.name == \"$PREVIOUS_SPECIAL_WORKSPACE\" or w.workspace.name == \"$LEGACY_SPECIAL_WORKSPACE\") then
      hl.dispatch(hl.dsp.window.move({ window = w, out_of_group = true }))
    end
  "
  hyprctl eval "
    local w = hl.get_window(\"address:$address\")
    if not w then error(\"Apple Music window disappeared\") end
    local cursor = hl.get_cursor_pos()
    local source_ws = w.workspace
    local source_name = source_ws and source_ws.name or \"\"
    local parked = source_name == \"$SPECIAL_WORKSPACE\" or source_name == \"$PREVIOUS_SPECIAL_WORKSPACE\" or source_name == \"$LEGACY_SPECIAL_WORKSPACE\"

    if not parked then
      -- The window is already in a user workspace (including a scratchpad).
      -- Focus it in place so Hyprland switches to that existing spot.
      hl.dispatch(hl.dsp.focus({ window = w }))
    else
      local target = $target_expr
      local target_group = target and target.group or nil
      -- A hidden Apple Music window can remain Hyprland's last active window.
      -- Always use the workspace currently shown by the monitor. A visible
      -- scratchpad takes precedence so opening Apple Music while it is open
      -- keeps Apple Music in that scratchpad; the Apple Music parking special
      -- workspace is deliberately never selected as a target.
      local target_name = nil
      if $empty_scratchpad or "$scratchpad_visible" == "true" then
        -- An empty Scratchpad is represented by the switcher's persistent
        -- hint, so Hyprland has no special-workspace object to query yet.
        -- Moving to this selector creates and reveals the real Scratchpad.
        target_name = \"special:scratchpad\"
        target_group = nil
      else
        target_name = \"$active_workspace_id\"
        -- The Apple Music parking workspaces are never valid destinations.
        -- Keep the target empty if Hyprland cannot report a normal workspace;
        -- focusing the hidden window must not expose its parking special.
        if target_name == \"$SPECIAL_WORKSPACE\" or target_name == \"$PREVIOUS_SPECIAL_WORKSPACE\" or target_name == \"$LEGACY_SPECIAL_WORKSPACE\" or target_name == \"\" then
          target_name = nil
        end
        if target_group and target.workspace and target_name and target.workspace.name ~= target_name then
          target_group = nil
        end
      end
      if target_name then
        hl.dispatch(hl.dsp.window.move({ window = w, workspace = target_name, follow = $empty_scratchpad or "$scratchpad_visible" == "true" }))
        -- A move into an already-present special workspace is queued. Flush
        -- that property refresh before focusing so Hyprland keeps the
        -- scratchpad visible instead of applying focus against the old
        -- parking workspace.
        hl.exec_scheduled_prop_refresh_immediately()
      end
      if target_group and w.group ~= target_group then
        target_group:add(w)
      end
      hl.dispatch(hl.dsp.focus({ window = w }))
    end
    if cursor and cursor.x and cursor.y then
      hl.dispatch(hl.dsp.cursor.move({ x = math.floor(cursor.x), y = math.floor(cursor.y) }))
    end
  "
  if [[ $empty_scratchpad == true ]]; then
    # The empty message is only a hint; once Apple Music supplies the first
    # Scratchpad window, remove that hint without toggling a new one on.
    omarchy-shell shell call io.github.leandro-3rne.window-switcher dismissScratchpadEmpty '{}' >/dev/null 2>&1 || true
  fi
}

# Parks the window on a hidden workspace instead of closing it — playback
# and the signed-in session keep going, same idea as minimizing. If Apple
# Music is part of a group, detach only that exact window first; otherwise
# Hyprland moves the whole group to the hidden workspace. Restores cursor
# position too, defensively matching show_window, in case moving a window
# across workspaces has the same pointer-warping side effect.
hide_window() {
  local address=$1 source_workspace source_was_scratchpad=false remaining_scratchpad was_fullscreen
  [[ $address =~ ^0x[0-9a-fA-F]+$ ]] || { echo "invalid address: $address" >&2; exit 2; }
  # Remember whether this exact window was the visible Scratchpad window. If
  # it is the last one there, close the now-empty special workspace just like
  # closing the last ordinary Scratchpad window does.
  source_workspace=$(hyprctl -j clients 2>/dev/null | jq -r --arg address "$address" '
    first(.[] | select(.address == $address)) | .workspace.name // empty
  ' 2>/dev/null || true)
  was_fullscreen=$(hyprctl -j clients 2>/dev/null | jq -r --arg address "$address" '
    first(.[] | select(.address == $address)) | (.fullscreen // 0) > 0
  ' 2>/dev/null || printf 'false')
  was_fullscreen=${was_fullscreen:-false}
  if [[ $source_workspace == "special:scratchpad" ]]; then
    if hyprctl -j monitors 2>/dev/null | jq -e 'any(.[]; .specialWorkspace.name == "special:scratchpad")' >/dev/null 2>&1; then
      source_was_scratchpad=true
    fi
  fi
  # Detaching and moving in a single Lua evaluation lets the workspace move
  # observe the old group on this Hyprland build. Complete the detach first,
  # then resolve the window again for the workspace move.
  hyprctl eval "
    local w = hl.get_window(\"address:$address\")
    if w and $was_fullscreen then
      hl.dispatch(hl.dsp.window.fullscreen({ window = w, mode = \"fullscreen\" }))
      hl.exec_scheduled_prop_refresh_immediately()
    end
    if w and w.group then
      hl.dispatch(hl.dsp.window.move({ window = w, out_of_group = true }))
    end
  "
  hyprctl eval "
    local cursor = hl.get_cursor_pos()
    local w = hl.get_window(\"address:$address\")
    hl.dispatch(hl.dsp.window.move({ window = w or \"address:$address\", workspace = \"$SPECIAL_WORKSPACE\", follow = false }))
    if cursor and cursor.x and cursor.y then
      hl.dispatch(hl.dsp.cursor.move({ x = math.floor(cursor.x), y = math.floor(cursor.y) }))
    end
  "
  if [[ $source_was_scratchpad == true ]]; then
    # Dispatches are asynchronous. Check for another Scratchpad client after
    # the move; only close the special workspace when Apple Music was the last
    # one, so a non-empty Scratchpad keeps its normal presentation untouched.
    remaining_scratchpad=$(hyprctl -j clients 2>/dev/null | jq -r --arg address "$address" '
      any(.[]; .workspace.name == "special:scratchpad" and .address != $address)
    ' 2>/dev/null || printf 'false')
    if [[ $remaining_scratchpad != true ]]; then
      if hyprctl -j monitors 2>/dev/null | jq -e 'any(.[]; .specialWorkspace.name == "special:scratchpad")' >/dev/null 2>&1; then
        hyprctl eval 'hl.dispatch(hl.dsp.workspace.toggle_special("scratchpad"))' >/dev/null 2>&1 || true
      fi
      # Do not leave a manually opened empty hint behind while the real
      # Scratchpad has just been closed.
      omarchy-shell shell call io.github.leandro-3rne.window-switcher dismissScratchpadEmpty '{}' >/dev/null 2>&1 || true
    fi
  fi
}

# The bar icon's one right-click action: launch if not running, hide if our
# window is sitting on the workspace the user is currently looking at,
# otherwise bring it into view. This only ever acts on our own window's
# address, never on whatever window happens to be active.
#
# Checks the *workspace* the window is on, not which window currently has
# input focus (e.g. via `hyprctl activewindow`). Omarchy runs with
# input:follow_mouse enabled, so the pointer travelling from the Apple Music
# window to the bar icon crosses other windows on the way and steals focus
# before the click is even processed — "was it focused a moment ago" isn't a
# question a script can answer reliably under that setting. Which workspace
# is active isn't affected by the pointer merely hovering another window on
# the same output, so it stays an accurate proxy for "is the user looking at
# this window right now."
toggle_window() {
  local current addr workspace visible
  current=$(state)
  if [[ $(jq -r '.open' <<<"$current") != "true" ]]; then
    launch
    return
  fi

  addr=$(jq -r '.address' <<<"$current")
  workspace=$(jq -r '.workspace' <<<"$current")
  visible=$(jq -r '.visible' <<<"$current")

  if [[ $workspace == "$SPECIAL_WORKSPACE" || $workspace == "$PREVIOUS_SPECIAL_WORKSPACE" || $workspace == "$LEGACY_SPECIAL_WORKSPACE" ]]; then
    show_window "$addr"
    return
  fi

  if [[ $workspace == special:* ]]; then
    if [[ $visible == true ]]; then
      hide_window "$addr"
    else
      show_window "$addr"
    fi
    return
  fi

  # Visibility is global across outputs, not relative to the clicked bar.
  if [[ $visible == true ]]; then
    hide_window "$addr"
  else
    show_window "$addr"
  fi
}

# Focusing the YouTube window must not move the entire browser into the
# dedicated Apple Music parking workspace or affect other browser windows.
focus_media_window() {
  local address=$1
  [[ $address =~ ^0x[0-9a-fA-F]+$ ]] || return 2
  hyprctl eval "
    local w = hl.get_window(\"address:$address\")
    if w then
      local cursor = hl.get_cursor_pos()
      hl.dispatch(hl.dsp.focus({ window = w }))
      if cursor and cursor.x and cursor.y then
        hl.dispatch(hl.dsp.cursor.move({ x = math.floor(cursor.x), y = math.floor(cursor.y) }))
      end
    end
  "
}

# Act only on the newest YouTube window, even if the bar was clicked from a
# different monitor. Re-resolve its address at click time, not popup-open time.
toggle_media_window() {
  local current address workspace visible
  current=$(state)
  address=${1:-}
  [[ $address =~ ^0x[0-9a-fA-F]+$ ]] || return 1
  # Validate the caller-selected window against the fresh list; a stale
  # address must never move some unrelated window into the music workspace.
  workspace=$(jq -r --arg address "$address" '
    first(.youtubeWindows[] | select(.address == $address)) | .workspace // ""
  ' <<<"$current")
  [[ -n $workspace ]] || return 1
  visible=$(jq -r --arg address "$address" '
    first(.youtubeWindows[] | select(.address == $address)) | .visible // false
  ' <<<"$current")
  if [[ $visible == true && $workspace != "$SPECIAL_WORKSPACE" ]]; then
    hide_window "$address"
  else
    show_window "$address"
  fi
}

show_media_window() {
  local address=$1
  [[ $address =~ ^0x[0-9a-fA-F]+$ ]] || return 1
  state | jq -e --arg address "$address" 'any(.youtubeWindows[]; .address == $address)' >/dev/null || return 1
  show_window "$address"
}

# Copies the cover art the browser is advertising into this plugin's own
# runtime directory, and prints the copy's path. `clear` removes any copy
# left behind instead.
#
# Both sides of this are held open rather than named twice. The source is
# opened once and judged on that descriptor — regular file, size, and image
# format from its leading bytes. The destination directory is opened without
# following its final component and confirmed on its descriptor to be ours
# and private; that same descriptor is then what the old copy is removed
# through and the new one created under, so a directory substituted after the
# check is not the one being written to.
#
# It lives under $XDG_RUNTIME_DIR: owner-only, per-session, and cleared when
# the session ends. If that is unavailable this does nothing rather than
# falling back to somewhere persistent, and the popover shows its placeholder.
art_helper() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$ART_MAX_BYTES" "$@" <<'PY'
import os
import re
import secrets
import stat
import sys

ceiling = int(sys.argv[1])
mode = sys.argv[2]
PREFIX = "art."
OWNER_NAME = re.compile(r"^[0-9a-f]{9,32}$")
SNAPSHOT_NAME = re.compile(r"^art\.([0-9a-f]{9,32})\.[0-9a-f]{16}$")
LEGACY_SNAPSHOT_NAME = re.compile(r"^art\.[0-9a-f]{16}$")
BASE = "leandro-3rne-apple-music"
ART = "art"


def open_dir(name, parent_fd=None, repair=False):
    """Open a directory without following its final component, then judge it
    by the descriptor: a real directory, owned by us, closed to everyone
    else. `repair` tightens a directory of ours that a umask left loose."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if parent_fd is None:
        fd = os.open(name, flags)
    else:
        fd = os.open(name, flags, dir_fd=parent_fd)
    try:
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise OSError("not an owned directory")
        if info.st_mode & 0o077:
            if not repair:
                raise OSError("directory is not private")
            os.fchmod(fd, 0o700)
            if os.fstat(fd).st_mode & 0o077:
                raise OSError("directory could not be made private")
    except Exception:
        os.close(fd)
        raise
    return fd


def make_dir(name, parent_fd):
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    except FileExistsError:
        pass
    return open_dir(name, parent_fd, repair=True)


runtime = os.environ.get("XDG_RUNTIME_DIR", "")
# A trailing slash makes the final component a directory reference rather than
# a name, and O_NOFOLLOW then has nothing to refuse — so it is taken off
# before that path is ever opened.
runtime = runtime.rstrip("/") or "/"
if not runtime.startswith("/"):
    sys.exit(1)

try:
    # Never repaired: the session owns this one, we only decline to use it.
    runtime_fd = open_dir(runtime)
except OSError:
    sys.exit(1)

owner = None
if mode != "clear":
    owner = sys.argv[3]
    if not OWNER_NAME.fullmatch(owner):
        sys.exit(1)

base_fd = art_fd = None
try:
    if mode == "clear":
        try:
            base_fd = open_dir(BASE, runtime_fd, repair=True)
            art_fd = open_dir(ART, base_fd, repair=True)
        except OSError:
            sys.exit(0)
    else:
        try:
            base_fd = make_dir(BASE, runtime_fd)
            art_fd = make_dir(ART, base_fd)
        except OSError:
            # Something other than our own private directory is sitting at
            # that name; leave it alone and go without artwork.
            sys.exit(1)

    # A replacement bar can host several independent Service instances. During
    # a snapshot, remove only this instance's previous file; otherwise one bar
    # can delete artwork that another bar is still decoding or displaying.
    # A full clear still removes every current and legacy plugin snapshot.
    for name in os.listdir(art_fd):
        match = SNAPSHOT_NAME.fullmatch(name)
        removable = (mode == "clear" and (match or LEGACY_SNAPSHOT_NAME.fullmatch(name))) \
            or (mode != "clear" and match and match.group(1) == owner)
        if not removable:
            continue
        try:
            os.unlink(name, dir_fd=art_fd)
        except IsADirectoryError:
            try:
                os.rmdir(name, dir_fd=art_fd)
            except OSError:
                pass
        except OSError:
            pass

    if mode == "clear":
        os.close(art_fd)
        art_fd = None
        try:
            os.rmdir(ART, dir_fd=base_fd)
        except OSError:
            pass
        os.close(base_fd)
        base_fd = None
        try:
            os.rmdir(BASE, dir_fd=runtime_fd)
        except OSError:
            pass
        sys.exit(0)

    src = sys.argv[4]
    try:
        src_fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        sys.exit(1)
    try:
        info = os.fstat(src_fd)
        if not stat.S_ISREG(info.st_mode):
            sys.exit(1)
        if info.st_size <= 0 or info.st_size > ceiling:
            sys.exit(1)
        chunks, total = [], 0
        while total <= ceiling:
            chunk = os.read(src_fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
    finally:
        os.close(src_fd)

    data = b"".join(chunks)
    if not data or len(data) > ceiling:
        sys.exit(1)
    if not (data.startswith(b"\x89PNG\r\n\x1a\n")
            or data.startswith(b"\xff\xd8\xff")
            or data[:6] in (b"GIF87a", b"GIF89a")
            or (data[:4] == b"RIFF" and data[8:12] == b"WEBP")):
        sys.exit(1)

    name = PREFIX + owner + "." + secrets.token_hex(8)
    out_fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=art_fd)
    try:
        os.fchmod(out_fd, 0o600)
        written = 0
        while written < len(data):
            written += os.write(out_fd, data[written:])
    finally:
        os.close(out_fd)

    sys.stdout.write(os.path.join(runtime, BASE, ART, name))
finally:
    for fd in (art_fd, base_fd, runtime_fd):
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
PY
}

snapshot_art() {
  local owner=$1 src=$2
  [[ $owner =~ ^[0-9a-f]{9,32}$ ]] || return 1
  [[ $src =~ ^/tmp/\.org\.chromium\.Chromium\.[A-Za-z0-9]+$ ]] || return 1
  art_helper snapshot "$owner" "$src"
}

clear_art() {
  art_helper clear >/dev/null 2>&1 || true
}

# Asks the browser to close and waits for every process on this profile to
# actually exit. Chromium writes its profile out on the way down, so deleting
# the profile before those writes finish would leave part of it behind; the
# wait is what makes a removal come out clean. SIGTERM rather than SIGKILL, so
# it shuts down and flushes normally instead of being left in a crashed state.
stop_browser() {
  local pid attempt
  pid=$(browser_pid || true)
  if [[ -n $pid ]]; then
    kill "$pid" 2>/dev/null || true
  fi
  for attempt in {1..100}; do
    pgrep -f -- "--user-data-dir=$PROFILE_DIR" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
}

# Close the dedicated Apple Music browser immediately. SIGTERM cannot be
# cancelled by the page's beforeunload handler, but unlike SIGKILL it still
# gives Chromium its normal profile-shutdown path.
close_window() {
  stop_browser
  clear_art
}

# Whether the shell still lists this plugin as enabled.
plugin_still_enabled() {
  local listing
  listing=$(omarchy-shell shell listPlugins 2>/dev/null) || return 1
  [[ -n $listing ]] || return 1
  jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id and .enabled == true)' \
    <<<"$listing" >/dev/null 2>&1
}

# Shuts down the dedicated browser when the plugin's enabled state flips to
# false (see Service.qml's handleDisabled), so a signed-in session doesn't
# outlive the UI that was managing it.
#
# A disable and a removal both arrive here: `omarchy plugin remove` disables
# the plugin first and deletes its folder immediately after. Waiting a beat and
# then looking for that folder settles which one happened.
quit_window() {
  sleep 2

  if [[ ! -e "$PLUGIN_DIR/manifest.json" ]]; then
    # The plugin folder is gone: this was a removal, so the profile — the
    # cache and signed-in session for this window — goes with it rather than
    # being left behind with nothing to manage it. The delete is pinned to an
    # absolute path that is this plugin's own data directory, and to a real
    # directory rather than a link standing in for one, so neither an unset
    # HOME nor a substituted path can point it somewhere else.
    stop_browser
    clear_art
    if [[ $DATA_DIR == /*/leandro-3rne-apple-music && ! -L $DATA_DIR && -d $DATA_DIR ]]; then
      rm -rf -- "$DATA_DIR"
    fi
    return 0
  fi

  # The folder is still there, so the plugin was switched off rather than
  # removed: close the window but keep the profile, so toggling the plugin
  # off and on doesn't cost the user their signed-in session. Confirmed
  # against the shell first — a plugin that reports as enabled by now was
  # never really switched off, and a window the user is still using should
  # not be closed on the strength of a momentary reload.
  if plugin_still_enabled; then
    return 0
  fi
  stop_browser
  clear_art
}

case ${1:-} in
state) state ;;
remember) remember_playback "${2:-}" "${3:-}" "${4:-}" ;;
launch) launch ;;
show)
  (( $# == 2 || $# == 3 )) || { echo "usage: $0 show <address> [group-target-address]" >&2; exit 2; }
  show_window "$2" "${3:-}"
  ;;
toggle) toggle_window ;;
focus-media) focus_media_window "${2:-}" ;;
toggle-media) toggle_media_window "${2:-}" ;;
show-media) show_media_window "${2:-}" ;;
close) close_window ;;
quit) quit_window ;;
art)
  (( $# == 3 )) || { echo "usage: $0 art <owner> <path>" >&2; exit 2; }
  snapshot_art "$2" "$3" || exit 1
  ;;
storefront)
  (( $# == 2 )) || { echo "usage: $0 storefront <country-code>" >&2; exit 2; }
  set_storefront "$2"
  ;;
*)
  echo "usage: $0 <state|launch|show|toggle|toggle-media|focus-media|close|quit|art|storefront>" >&2
  exit 2
  ;;
esac
