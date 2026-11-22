# Sourced by swapkin. `swapkin statusline on|off|status|install|uninstall`: put
# the active account in Claude Code's status line, and take it out again.
#
# Two layers. The setting (statusLine, per provider, in $ACCOUNTS/settings.json,
# on when absent) is what `swapkin statusline` itself obeys: off prints nothing,
# so Off works however the user wired it, even by hand. Install is only the
# wiring into settings.json, and `on` does it only when nothing calls
# `swapkin statusline` yet.
#
# Only ~/.claude/settings.json (or $CLAUDE_CONFIG_DIR/settings.json) is edited:
# with jq, through a temp file and rename, after a copy to settings.json.swapkin-bak.
# A status line the user already has is never replaced. It is wrapped: a small
# script runs the original command, then adds the swapkin segment. The original
# setting is kept verbatim in the data dir, and uninstall puts it back.

sl_settings() { printf '%s/settings.json' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }
sl_wrapper()  { printf '%s/statusline-wrap.sh' "$ACCOUNTS"; }
sl_saved()    { printf '%s/statusline-original.json' "$ACCOUNTS"; }

# Write stdin to $1 atomically (temp file in the same directory, then rename).
sl_write() {
  local target tmp; target=$(readlink -f "$1")
  tmp=$(mktemp "$target.swapkin-tmp.XXXXXX") || return 1
  cat > "$tmp" && jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  chmod --reference="$target" "$tmp" 2>/dev/null || chmod 644 "$tmp"
  mv -f "$tmp" "$target"
}

sl_prefs() { printf '%s/settings.json' "$ACCOUNTS"; }

sl_enabled() { # provider id; true unless the setting says false
  [[ $(jq -r --arg p "$1" 'if (.statusLine|type)=="object" then (.statusLine[$p] | if . == null then true else . end) else true end' "$(sl_prefs)" 2>/dev/null) != false ]]
}

sl_set_enabled() { # provider id, true|false
  local f; f=$(sl_prefs); mkdir -p "$ACCOUNTS"
  [[ -f $f ]] || echo '{}' > "$f"
  jq --arg p "$1" --argjson v "$2" '(if (.statusLine|type)=="object" then . else .statusLine = {} end) | .statusLine[$p] = $v' "$f" | sl_write "$f"
}

# Does the user's own status line already call `swapkin statusline`, directly or
# through the script it runs?
sl_hand_wired() {
  local f cmd; f=$(sl_settings)
  [[ -f $f ]] || return 1
  cmd=$(jq -r '.statusLine.command // empty' "$f" 2>/dev/null)
  [[ -n $cmd ]] || return 1
  grep -Eq 'swapkin.*[[:space:]]statusline' <<<"$cmd" && return 0
  # Every word may be a script (`bash script.sh`, or a wrapper taking the real
  # command as a quoted argument), so look inside each file that is named.
  local tok
  for tok in ${cmd//[\"\']/ }; do
    tok="${tok/#\~/$HOME}"
    [[ -f $tok && -r $tok ]] && grep -Eq 'swapkin.*[[:space:]]statusline' "$tok" && return 0
  done
  return 1
}

# What the settings file points at: off, plain (ours alone), wrapped, or hand.
sl_state() {
  local f; f=$(sl_settings)
  [[ -f $f ]] || { echo off; return; }
  local cmd; cmd=$(jq -r '.statusLine.command // empty' "$f" 2>/dev/null) || { echo off; return; }
  if [[ $cmd == "$(sl_wrapper)" || $cmd == "'$(sl_wrapper)'" ]]; then echo wrapped
  elif [[ $cmd == "'$SCRIPT_DIR/swapkin' statusline" ]]; then echo plain
  elif sl_hand_wired; then echo hand
  else echo off; fi
}

sl_make_wrapper() {
  local w; w=$(sl_wrapper)
  mkdir -p "$ACCOUNTS"
  cat > "$w.tmp" <<WRAP
#!/usr/bin/env bash
# Written by swapkin. Runs your original status line command, then adds @account.
input=\$(cat)
orig=\$(jq -r '.command // empty' '$(sl_saved)' 2>/dev/null)
if [[ -n \$orig ]]; then
  out=\$(printf '%s' "\$input" | bash -c "\$orig" 2>/dev/null)
  [[ -n \$out ]] && printf '%s\n' "\$out"
fi
'$SCRIPT_DIR/swapkin' statusline
WRAP
  chmod +x "$w.tmp" && mv -f "$w.tmp" "$w"
}

sl_install() { # provider id
  command -v jq >/dev/null || die "jq is required"
  sl_set_enabled "$1" true
  local f state; f=$(sl_settings); state=$(sl_state)
  [[ $state == off ]] || { echo "Already installed."; return 0; }
  mkdir -p "$(dirname "$f")"
  [[ -f $f ]] || echo '{}' > "$f"
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || die "$f is not a JSON object; not touching it"
  cp -p "$f" "$f.swapkin-bak" || die "could not write the backup"
  local ours="'$SCRIPT_DIR/swapkin' statusline" new
  if jq -e '.statusLine != null' "$f" >/dev/null; then
    jq -e '.statusLine | type == "object" and .type == "command" and ((.command // "") != "")' "$f" >/dev/null \
      || die "your statusLine is not a command; not touching it"
    jq '.statusLine' "$f" > "$(sl_saved).tmp" && mv -f "$(sl_saved).tmp" "$(sl_saved)" || die "could not save the original"
    sl_make_wrapper || die "could not write the wrapper"
    new=$(jq --arg c "$(sl_wrapper)" '.statusLine.command = $c' "$f") || die "edit failed"
    echo "Wrapped your status line. Uninstall restores it."
  else
    new=$(jq --arg c "$ours" '.statusLine = {type: "command", command: $c}' "$f") || die "edit failed"
    echo "Status line set to show your account."
  fi
  printf '%s\n' "$new" | sl_write "$f" || die "could not write $f"
}

sl_uninstall() {
  command -v jq >/dev/null || die "jq is required"
  local f state; f=$(sl_settings); state=$(sl_state)
  case $state in
    off|hand) echo "Not installed."; return 0 ;;
    plain) jq 'del(.statusLine)' "$f" | sl_write "$f" || die "could not write $f" ;;
    wrapped)
      [[ -f $(sl_saved) ]] || die "the saved original is missing; restore from $f.swapkin-bak"
      jq --slurpfile o "$(sl_saved)" '.statusLine = $o[0]' "$f" | sl_write "$f" || die "could not write $f"
      rm -f "$(sl_saved)" "$(sl_wrapper)" ;;
  esac
  echo "Removed. Your status line is as it was."
}

# The panel's switch. On is the setting plus the wiring when nothing is wired;
# Off is the setting, plus unwiring only what swapkin itself wired.
sl_on() {
  command -v jq >/dev/null || die "jq is required"
  sl_set_enabled "$1" true || die "could not save the setting"
  [[ $(sl_state) == off ]] && sl_install "$1" || echo "Shown."
}
sl_off() {
  command -v jq >/dev/null || die "jq is required"
  sl_set_enabled "$1" false || die "could not save the setting"
  case $(sl_state) in plain|wrapped) sl_uninstall ;; *) echo "Hidden." ;; esac
}
sl_status() { # on only when the setting is on AND something shows it
  sl_enabled "$1" && [[ $(sl_state) != off ]] && echo on || echo off
}

# Adapters opt in by defining p_statusline_install/uninstall/status/on/off,
# which call these with their id. A provider without them has no such switch.
cmd_statusline_setup() { # install | uninstall | on | off | status
  local fn="p_statusline_$1"
  declare -F "$fn" >/dev/null || die "the status line is not supported for $P_ID"
  "$fn"
}
