# shellcheck shell=bash
# Auto-switch engine shared by every provider that `swapkin check` watches.
# Sourced by bin/swapkin. Uses whichever adapter is loaded (P_ID, profiles,
# active, account_dir, p_use) and an optional adapter hook:
#   p_plausible_login <account>   true when the saved login can be a real one.

CONFIG="$ACCOUNTS/config.json"
STATE_FILE="$ACCOUNTS/watch.json"

# The widget settings reach `check` as SWAPKIN_<KEY> (Service.qml sets them);
# they win over config.json, which stays the fallback for older setups.
setting() { # key default
  local env="SWAPKIN_${1^^}"
  if [[ -n ${!env:-} ]]; then echo "${!env}"; return; fi
  jq -r --arg k "$1" --arg d "$2" '.[$k] // $d' "$CONFIG" 2>/dev/null || echo "$2"
}

# Same two-circle mark the panel draws for this account: a solid disc in its
# colour overlapped by an outline ring. One icon per palette colour ships with
# the plugin, so nothing is written to disk to show a notification. A colour
# outside the palette gets the neutral mark.
icon_for() { # account
  local colour="" c
  [[ ${1:-} =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] && colour=$(colour_of "$1")
  colour=${colour,,}
  for c in "${PALETTE[@]}"; do
    [[ $c == "$colour" ]] && { echo "$ICONS/account-${c#\#}.svg"; return; }
  done
  echo "$ICONS/account-default.svg"
}

notify() { # title body account
  command -v notify-send >/dev/null || return 0
  notify-send --app-name=Swapkin --icon="$(icon_for "${3:-}")" "$1" "$2" || true
}

# ---- Auto-switch ------------------------------------------------------------
# Figures in usage.json are a fraction used (0..1); "left" is percent remaining.

AUTO_CTX=""
AUTO_PROV=""   # provider name in every log line; empty for Claude (the original lines)
AUTO_FOLLOW="Open sessions follow on their next message."
AUTO_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/swapkin/autoswitch.log"

auto_log() { # message; one line per decision, last 200 kept; a repeat only bumps the time and a count
  mkdir -p "$(dirname "$AUTO_LOG")"
  local last n=1 stamp msg="${AUTO_CTX:+$AUTO_CTX }$1"; stamp=$(date '+%Y-%m-%dT%H:%M:%S')
  last=$(tail -n 1 "$AUTO_LOG" 2>/dev/null | cut -d' ' -f2- || true)
  if [[ ${last% (x*)} == "$msg" ]]; then
    [[ $last =~ \(x([0-9]+)\)$ ]] && n=${BASH_REMATCH[1]}
    n=$((n + 1))
    sed -i '$d' "$AUTO_LOG"
    printf '%s %s (x%d)\n' "$stamp" "$msg" "$n" >> "$AUTO_LOG"
    return 0
  fi
  printf '%s %s\n' "$stamp" "$msg" >> "$AUTO_LOG"
  if (( $(wc -l < "$AUTO_LOG") > 200 )); then
    tail -n 200 "$AUTO_LOG" > "$AUTO_LOG.tmp" && mv "$AUTO_LOG.tmp" "$AUTO_LOG"
  fi
}

# Seconds since the account's figures were written; huge when there are none.
usage_age() { # account
  echo $(( $(date +%s) - $(stat -c %Y "$(account_dir "$1")/usage.json" 2>/dev/null || echo 0) ))
}

# The tightest limit as "<left>\t<label>\t<window key>\t<reset epoch>"; nothing
# when the figures are missing or unreadable. Weekly windows are keyed by day,
# short ones by the hour, so the API's sub-second jitter never reads as a new window.
tightest_limit() { # account
  jq -r '
    [.limits[]? | select((.percent | type) == "number")
     | {label, left: (((1 - .percent) * 10000 | round) / 100), reset: (.resetsAt // "")}]
    | if length == 0 then empty else
        min_by(.left)
        | (.reset | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdate catch 0) as $e
        | [.left, .label,
           (if (.label | ascii_downcase | test("week|month")) then (.reset | .[0:10])
            else ((($e + 1800) / 3600 | floor) | tostring) end),
           $e] | @tsv end' "$(account_dir "$1")/usage.json" 2>/dev/null
}

room_of() { # account -> percent left on its tightest limit, empty if unknown
  tightest_limit "$1" | cut -f1
}

# The roomiest other account that would not trigger straight away: a real login,
# fresh figures, more than the threshold left on every limit, and not one we
# already left because a limit ran out (until that limit resets).
auto_target() { # current threshold
  local best="" best_room=-1 name room until now; now=$(date +%s)
  for name in $(profiles); do
    [[ $name == "$1" ]] && continue
    auto_plausible "$name" || continue
    (( $(usage_age "$name") <= 7200 )) || continue
    room=$(room_of "$name"); [[ -n $room ]] || continue
    awk -v r="$room" -v t="$2" 'BEGIN{exit !(r > t)}' || continue
    until=$(jq -r --arg a "$name" '[.[$a] // {} | to_entries[] | select(.key | startswith("auto|")) | .value] | max // 0' "$STATE_FILE" 2>/dev/null || echo 0)
    (( until > now )) && continue
    if awk -v r="$room" -v b="$best_room" 'BEGIN{exit !(r > b)}'; then best="$name"; best_room="$room"; fi
  done
  echo "$best"
}

state_set() { # jq-filter [jq args...]; edits STATE_FILE atomically, old state is $old
  local filter="$1"; shift
  local tmp; tmp=$(mktemp "$STATE_FILE.XXXXXX")
  jq "$@" --slurpfile old <(cat "$STATE_FILE" 2>/dev/null || echo '{}') "($filter)" -n > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_get() { # account key
  jq -r --arg a "$1" --arg k "$2" '.[$a][$k] // 0' "$STATE_FILE" 2>/dev/null || echo 0
}

# The same switch the panel makes, under the panel's lock. Exit 3: lock busy.
auto_use() { # from to
  ( exec 9>"$ACCOUNTS/.lock"; flock -w 10 9 || exit 3
    [[ $(active) == "$1" ]] || exit 4   # the owner switched meanwhile
    p_use "$2" >/dev/null )
}
# Hand over before the active account runs dry, or hand back once it recovers.
# Returns 0 when a switch happened.
auto_switch_run() { # current
  # Every line carries the settings of the run, so a changed setting always logs.
  AUTO_CTX="[${AUTO_PROV:+$AUTO_PROV }autoSwitch=$(setting autoSwitch false) leftPct=$(setting autoSwitchLeftPct 5) return=$(setting autoSwitchReturn false)]"
  if [[ $(setting autoSwitch false) != true ]]; then auto_log "skipped: auto-switch is off"; return 1; fi
  local cur="$1" left; left=$(setting autoSwitchLeftPct 5)
  [[ $left =~ ^[0-9]+$ ]] || left=5

  if (( $(usage_age "$cur") > 7200 )); then auto_log "skipped: figures for $cur are stale"; return 1; fi
  local tight; tight=$(tightest_limit "$cur")
  if [[ -z $tight ]]; then auto_log "skipped: figures for $cur are unreadable"; return 1; fi
  local room label key reset
  IFS=$'\t' read -r room label key reset <<<"$tight"
  local pretty; pretty=$(awk -v r="$room" 'BEGIN{printf "%d", r + 0.5}')

  if awk -v r="$room" -v t="$left" 'BEGIN{exit !(r <= t)}'; then
    local mark="auto|$label|$key" warned="warn|$label|$key"
    [[ $(state_get "$cur" "$mark") == 0 ]] || return 1   # this window already had its switch
    local other; other=$(auto_target "$cur" "$left")
    if [[ -z $other ]]; then
      if [[ $(state_get "$cur" "$warned") == 0 ]]; then
        auto_log "skipped: $cur has ${pretty}% left on $label and no other account has room"
        notify "$cur has ${pretty}% left on $label" "No other account has room." "$cur"
        state_set '$old[0] * {($a): {($m): 1}}' --arg a "$cur" --arg m "$warned"
      fi
      return 1
    fi
    local rc=0; auto_use "$cur" "$other" || rc=$?
    if (( rc != 0 )); then auto_log "skipped: could not switch $cur -> $other (exit $rc)"; return 1; fi
    state_set '$old[0] * {($a): {($m): $e}, "_auto": {from: $a, to: $b}}' \
      --arg a "$cur" --arg b "$other" --arg m "$mark" --argjson e "${reset:-0}"
    auto_log "switched $cur -> $other: $label had ${pretty}% left"
    notify "Switched to $other" "$cur had ${pretty}% left on $label. $AUTO_FOLLOW" "$other"
    return 0
  fi

  # Not low: maybe hand back to the account we left.
  auto_log "skipped: $cur has ${pretty}% left on $label, above the ${left}% threshold"
  [[ $(setting autoSwitchReturn false) == true ]] || return 1
  local from to
  from=$(jq -r '._auto.from // ""' "$STATE_FILE" 2>/dev/null); to=$(jq -r '._auto.to // ""' "$STATE_FILE" 2>/dev/null)
  [[ -n $from ]] || return 1
  if [[ $to != "$cur" || ! -d $(account_dir "$from") ]]; then   # moved by hand: forget
    state_set '$old[0] | del(._auto)'; return 1
  fi
  auto_plausible "$from" && (( $(usage_age "$from") <= 7200 )) || return 1
  local back; back=$(room_of "$from"); [[ -n $back ]] || return 1
  awk -v b="$back" -v t="$left" -v c="$room" 'BEGIN{exit !(b > t && b > c)}' || return 1
  local rc=0; auto_use "$cur" "$from" || rc=$?
  if (( rc != 0 )); then auto_log "skipped: could not switch back to $from (exit $rc)"; return 1; fi
  state_set '$old[0] | del(._auto)'
  auto_log "returned $cur -> $from: $from recovered"
  notify "Switched back to $from" "$from has room again." "$from"
  return 0
}

auto_plausible() { # account; adapters without the hook count every saved account
  if declare -F p_plausible_login >/dev/null; then p_plausible_login "$1"; else return 0; fi
}

# The watchdog's turn for Codex: same settings, log and staleness guard as
# Claude, own state file. Needs 2+ saved accounts. The Claude adapter must be
# done first: loading the Codex adapter replaces p_use and friends.
codex_check() {
  load_adapter codex
  declare -F p_housekeeping >/dev/null && p_housekeeping
  local n; n=$(profiles | wc -l)
  (( n >= 2 )) || return 0
  cmd_usage
  local cur; cur=$(active)
  [[ -n $cur ]] || return 0
  STATE_FILE="$(provider_root codex)/watch.json"
  AUTO_PROV=codex
  AUTO_FOLLOW="New Codex sessions use it. Open ones keep their account."
  auto_switch_run "$cur" || true
}
