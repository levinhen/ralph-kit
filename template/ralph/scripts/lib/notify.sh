#!/bin/bash

ralph_notifications_enabled() {
  case "${RALPH_NOTIFY:-1}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      return 1
      ;;
  esac

  return 0
}

ralph_sounds_enabled() {
  case "${RALPH_NOTIFY_SOUND:-1}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      return 1
      ;;
  esac

  return 0
}

notify_ralph_macos() {
  local title="$1"
  local body="$2"

  if ! command -v osascript >/dev/null 2>&1; then
    return 1
  fi

  osascript - "$title" "$body" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}

notify_ralph_linux() {
  local title="$1"
  local body="$2"

  if ! command -v notify-send >/dev/null 2>&1; then
    return 1
  fi

  notify-send "$title" "$body" >/dev/null 2>&1
}

play_ralph_sound_macos() {
  local sound_file

  if command -v afplay >/dev/null 2>&1; then
    for sound_file in \
      /System/Library/Sounds/Glass.aiff \
      /System/Library/Sounds/Ping.aiff \
      /System/Library/Sounds/Hero.aiff; do
      if [[ -f "$sound_file" ]]; then
        afplay "$sound_file" >/dev/null 2>&1 &
        return 0
      fi
    done
  fi

  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'beep' >/dev/null 2>&1 &
    return 0
  fi

  return 1
}

play_ralph_sound_linux() {
  local sound_file

  if command -v canberra-gtk-play >/dev/null 2>&1; then
    canberra-gtk-play -i complete -d "Ralph" >/dev/null 2>&1 &
    return 0
  fi

  if command -v paplay >/dev/null 2>&1; then
    for sound_file in \
      /usr/share/sounds/freedesktop/stereo/complete.oga \
      /usr/share/sounds/freedesktop/stereo/message.oga \
      /usr/share/sounds/freedesktop/stereo/bell.oga; do
      if [[ -f "$sound_file" ]]; then
        paplay "$sound_file" >/dev/null 2>&1 &
        return 0
      fi
    done
  fi

  if running_in_wsl; then
    return 1
  fi

  printf '\a' >/dev/tty 2>/dev/null || printf '\a'
}

play_ralph_sound_windows() {
  if ! command -v powershell.exe >/dev/null 2>&1; then
    return 1
  fi

  powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command \
    '[Console]::Beep(880, 180); [Console]::Beep(1175, 180)' >/dev/null 2>&1
}

notify_ralph_windows() {
  local title="$1"
  local body="$2"

  if ! command -v powershell.exe >/dev/null 2>&1; then
    return 1
  fi

  RALPH_NOTIFY_TITLE="$title" RALPH_NOTIFY_BODY="$body" \
    powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command '
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$notification = New-Object System.Windows.Forms.NotifyIcon
$notification.Icon = [System.Drawing.SystemIcons]::Information
$notification.BalloonTipTitle = $env:RALPH_NOTIFY_TITLE
$notification.BalloonTipText = $env:RALPH_NOTIFY_BODY
$notification.Visible = $true
$notification.ShowBalloonTip(5000)
Start-Sleep -Seconds 5
$notification.Dispose()
' >/dev/null 2>&1
}

running_in_wsl() {
  [[ -r /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null
}

play_ralph_sound() {
  local os_name

  if ! ralph_notifications_enabled || ! ralph_sounds_enabled; then
    return 0
  fi

  os_name="$(uname -s 2>/dev/null || echo unknown)"
  case "$os_name" in
    Darwin*)
      play_ralph_sound_macos || true
      ;;
    Linux*)
      play_ralph_sound_linux \
        || { running_in_wsl && play_ralph_sound_windows; } \
        || true
      ;;
    MINGW*|MSYS*|CYGWIN*)
      play_ralph_sound_windows || true
      ;;
  esac

  return 0
}

notify_ralph() {
  local title="$1"
  local body="$2"
  local os_name

  if ! ralph_notifications_enabled; then
    return 0
  fi

  os_name="$(uname -s 2>/dev/null || echo unknown)"
  case "$os_name" in
    Darwin*)
      notify_ralph_macos "$title" "$body" || true
      ;;
    Linux*)
      notify_ralph_linux "$title" "$body" \
        || { running_in_wsl && notify_ralph_windows "$title" "$body"; } \
        || true
      ;;
    MINGW*|MSYS*|CYGWIN*)
      notify_ralph_windows "$title" "$body" || true
      ;;
  esac

  play_ralph_sound

  return 0
}

notify_ralph_merged() {
  notify_ralph "Ralph completed" "run $RUN_ID_LABEL: $TARGET_BRANCH merged into $BASE_BRANCH"
}

notify_ralph_stories_completed() {
  notify_ralph "Ralph completed" "run $RUN_ID_LABEL: all stories complete"
}

notify_ralph_needs_attention() {
  notify_ralph "Ralph needs attention" "run $RUN_ID_LABEL: reached max iterations ($MAX_ITERATIONS)"
}

notify_ralph_rate_limited() {
  notify_ralph "Ralph paused" "run $RUN_ID_LABEL: 429/rate limit detected; skipped remaining iterations"
}
