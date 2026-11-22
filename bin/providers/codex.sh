# shellcheck shell=bash
# shellcheck disable=SC2034  # P_* vars are read by the engine after sourcing this file
# Codex adapter — cold. New sessions pick up the switched account; sessions
# already running keep whatever CODEX_HOME they started with, so nothing is
# rewritten under a process that might be holding it open.

P_ID=codex
P_NAME=Codex
P_MODE=cold
P_CMD=codex
P_MARKER=codex.json
P_STORE='$CODEX_HOME/auth.json'
P_HOMEVAR=CODEX_HOME
P_HOW="A switch reaches: new sessions and a plain codex. Sessions already running keep their account. Codex shares a background server; swapkin restarts it on a switch when no codex is open, else it tells you."
P_ADD_HINT="Add signs in a new account in a terminal; your current login is saved as the first one."

p_installed() { [[ -n $(tool_bin codex) ]]; }
p_has_login() { [[ -f ${CODEX_HOME:-$HOME/.codex}/auth.json || -f $HOME/.codex/auth.json ]]; }
p_sessions() { codex_open_sessions; } # real TUI sessions only, not the app-server daemon

home_of() { jq -r '.home // empty' "$(account_dir "$1")/codex.json" 2>/dev/null; } # name

# Shared by add and use: true only when a line starts with "Logged in",
# never on a substring match ("Not logged in" must not pass). A keyring-only
# login (no auth.json on disk) still reports logged in here, and that is
# enough — neither caller should also require auth.json to exist.
codex_logged_in() { # home
  local home="$1" cli status_out rc
  cli=$(tool_bin codex)
  [[ -n $cli ]] || return 1
  status_out=$(CODEX_HOME="$home" "$cli" login status 2>/dev/null)
  rc=$?
  (( rc == 0 )) || return 1
  grep -qE '^Logged in' <<<"$status_out"
}

write_codex_json() { # dir home
  jq -n --arg home "$2" '{home:$home}' > "$1/codex.json.tmp"
  mv "$1/codex.json.tmp" "$1/codex.json"
}

# No account may use the live Codex home as its own: a switch overwrites the
# live auth.json, so reads of that home would show another account. Give such
# an account a home under the data dir, seeded with its saved (else live) login.
own_home() { # name  -> prints its home, migrating if needed
  local name="$1" dir live home nh src f
  dir=$(account_dir "$name"); live="${CODEX_HOME:-$HOME/.codex}"
  home=$(home_of "$name")
  if [[ -n $home && ! ( $home -ef $live ) ]]; then printf '%s' "$home"; return; fi
  if [[ -f $dir/auth.json ]]; then src="$dir/auth.json"; else src="$live/auth.json"; fi
  # Keyring-only login: no file to copy, so the live home stays its home.
  [[ -f $src ]] || { printf '%s' "$home"; return; }
  nh="$(provider_root codex)/$name/home"
  mkdir -p "$nh"
  codex_copy_auth "$src" "$nh/auth.json" || die "could not copy $name's login"
  for f in config.toml AGENTS.md prompts skills rules; do
    [[ -e $live/$f ]] && ln -sfn "$live/$f" "$nh/$f"
  done
  write_codex_json "$dir" "$nh"
  printf '%s' "$nh"
}

p_add() { # name
  local name="${1:?usage: swapkin -p codex add <name>}"
  valid_name "$name"
  local dir; dir=$(account_dir "$name")
  [[ -e $dir/codex.json ]] && die "'$name' already exists"

  if [[ -z $(profiles) ]]; then
    local home="${CODEX_HOME:-$HOME/.codex}"
    [[ -f $home/auth.json ]] || codex_logged_in "$home" || die "no Codex login found in $home"
    mkdir -p "$dir"
    write_codex_json "$dir" "$home"
    own_home "$name" >/dev/null
    set_colour "$name" "$(next_colour "$name")"
    set_active "$name"
    echo "Saved the current Codex login as '$name'."
    return
  fi

  local home; home="$(provider_root codex)/$name/home"
  mkdir -p "$home"
  local default_home="${CODEX_HOME:-$HOME/.codex}" f
  for f in config.toml AGENTS.md prompts skills rules; do
    [[ -e $default_home/$f ]] && ln -sf "$default_home/$f" "$home/$f"
  done
  local cli; cli=$(tool_bin codex)
  [[ -n $cli ]] || fail "cannot find the codex command. Sign in manually and run: swapkin -p codex add $name"
  echo "Codex opens to sign in. Complete the flow; this returns once it's done."
  # An add must never move the live login. Keep a copy of it, and put it back
  # if the sign-in wrote there instead of into the new home (the shared Codex
  # background server can do that); the new login is then taken from the live file.
  local live="${CODEX_HOME:-$HOME/.codex}" keep=""
  if [[ -f $live/auth.json ]]; then
    keep=$(mktemp "$home/.live-keep.XXXXXX") && codex_copy_auth "$live/auth.json" "$keep" || keep=""
  fi
  CODEX_HOME="$home" "$cli" login -c 'cli_auth_credentials_store="file"' || true
  if [[ -n $keep ]]; then
    if ! cmp -s "$keep" "$live/auth.json"; then
      [[ -f $home/auth.json ]] || codex_copy_auth "$live/auth.json" "$home/auth.json" || true
      codex_copy_auth "$keep" "$live/auth.json" || true
    fi
    rm -f "$keep"
  fi
  [[ -f $home/auth.json ]] || fail "no sign-in found, so nothing was saved."
  mkdir -p "$dir"
  write_codex_json "$dir" "$home"
  set_colour "$name" "$(next_colour "$name")"
  echo "Saved '$name'. Switch with: swapkin -p codex use $name"
}

p_use() { # name
  local name="$1" dir; dir=$(account_dir "$name")
  [[ -f $dir/codex.json ]] || die "no saved account '$name'"
  local home; home=$(home_of "$name")
  [[ -n $home ]] || die "'$name' has no usable login; sign in again with: swapkin -p codex add $name"
  # Move the outgoing account off the live home first, while the live file is still its own.
  local cur; cur=$(active)
  [[ -n $cur && -f $(account_dir "$cur")/codex.json ]] && own_home "$cur" >/dev/null
  home=$(own_home "$name")
  # auth.json on disk is enough, but a keyring-only login that still reports
  # logged in (M3) must be accepted too — don't require the file to exist.
  [[ -f $home/auth.json ]] || codex_logged_in "$home" \
    || die "'$name' has no usable login; sign in again with: swapkin -p codex add $name"
  swap_live_auth "$name" "$dir" "$home"
  set_active "$name"
  echo "A plain 'codex' in a new terminal now uses $name. Open sessions keep their account."
  codex_reload_daemon "$cur"
}

# Codex 0.171 runs a long-lived "app-server daemon" (pid file in the live home)
# and a new codex talks to it ("Local background server"). The daemon keeps the
# login it loaded at start, so a new auth.json is not seen until it restarts.
# Restart it only when no codex session is open; otherwise say so.
codex_daemon_running() {
  local pf="${CODEX_HOME:-$HOME/.codex}/app-server-daemon/daemon.pid" pid
  [[ -f $pf ]] || return 1
  pid=$(jq -r '.pid // empty' "$pf" 2>/dev/null)
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}
# Open codex sessions, not counting the daemon's own processes.
codex_open_sessions() {
  local pid n=0
  for pid in ${SWAPKIN_CODEX_PIDS-$(pgrep -x codex 2>/dev/null)}; do
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'app-server' || n=$((n+1))
  done
  echo "$n"
}
# A skipped restart is remembered in a marker file (it holds the account the
# daemon still serves). `check`, `list`, `use` and the panel's refresh finish
# the job as soon as no codex session is open.
codex_pending_file() { echo "$(provider_root codex)/reload-pending"; }
codex_pending_old() { # prints the account the daemon still serves, or nothing
  local f old; f=$(codex_pending_file)
  [[ -f $f ]] || return 0
  read -r old < "$f" || true
  echo "${old:-the old account}"
}
codex_restart_daemon() { # 0 when restarted
  local cli; cli=$(tool_bin codex)
  [[ -n $cli ]] && timeout 30 "$cli" app-server daemon restart >/dev/null 2>&1
}
# One detached waiter per marker: polls every second (SWAPKIN_CODEX_POLL) for up
# to 6 hours and restarts the daemon the moment no codex session is open, so a
# quick quit-and-reopen is not missed. One instance only (flock on a lock file).
codex_start_waiter() {
  local f cli pf lock; f=$(codex_pending_file); lock="$f.waiter"
  cli=$(tool_bin codex); pf="${CODEX_HOME:-$HOME/.codex}/app-server-daemon/daemon.pid"
  [[ -n $cli ]] || return 0
  local script='
exec 9>"$4" || exit 0
flock -n 9 || exit 0
open() { local p n=0; for p in ${SWAPKIN_CODEX_PIDS-$(pgrep -x codex 2>/dev/null)}; do
  [[ -r /proc/$p/cmdline ]] || continue
  tr "\0" " " < "/proc/$p/cmdline" 2>/dev/null | grep -q app-server || n=$((n+1)); done; echo $n; }
alive() { local p; [[ -f $3 ]] || return 1; p=$(jq -r ".pid // empty" "$3" 2>/dev/null)
  [[ $p =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; }
end=$((SECONDS+21600))
while (( SECONDS < end )) && [[ -f $1 ]]; do
  alive "$@" || { rm -f "$1"; exit 0; }
  if (( $(open) == 0 )); then
    if timeout 30 "$2" app-server daemon restart >/dev/null 2>&1; then rm -f "$1"; exit 0; fi
    sleep 30
  else sleep "${SWAPKIN_CODEX_POLL:-1}"; fi
done'
  if command -v setsid >/dev/null 2>&1; then
    setsid -f bash -c "$script" _ "$f" "$cli" "$pf" "$lock" </dev/null >/dev/null 2>&1 9>&-
  else
    nohup bash -c "$script" _ "$f" "$cli" "$pf" "$lock" </dev/null >/dev/null 2>&1 9>&- &
  fi
  return 0
}
codex_reload_daemon() { # [old account]
  local old="${1:-}" f; f=$(codex_pending_file)
  if ! codex_daemon_running; then rm -f "$f"; return 0; fi
  local n; n=$(codex_open_sessions)
  if (( n > 0 )); then
    # Keep the first old name: the daemon still serves the login it started with.
    [[ -f $f ]] || { mkdir -p "$(dirname "$f")"; printf '%s\n' "$old" > "$f"; }
    codex_start_waiter
    echo "Codex is open in $n session(s) and shares a background server that still has the old login. The switch finishes by itself the moment the last Codex closes."
  elif codex_restart_daemon; then
    rm -f "$f"
    echo "Restarted the Codex background server so a new codex uses the new login."
  else
    [[ -f $f ]] || { mkdir -p "$(dirname "$f")"; printf '%s\n' "$old" > "$f"; }
    echo "Could not restart the Codex background server. Run: codex app-server daemon restart"
  fi
}
# Silent: finish a pending restart once no codex session is open.
p_housekeeping() {
  [[ -f $(codex_pending_file) ]] || return 0
  codex_daemon_running || { rm -f "$(codex_pending_file)"; return 0; }
  (( $(codex_open_sessions) == 0 )) || return 0
  codex_restart_daemon && rm -f "$(codex_pending_file)"
  return 0
}

# Copy a file atomically (same folder, owner-only), never leaving a half file.
codex_copy_auth() { # src dest
  local tmp; tmp=$(mktemp "$2.XXXXXX") || return 1
  cp "$1" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$2" || { rm -f "$tmp"; return 1; }
}

# Who an auth.json belongs to: tokens.account_id, else the id_token's email/sub.
codex_identity() { # file
  local id jwt body
  id=$(jq -r '.tokens.account_id // empty' "$1" 2>/dev/null)
  if [[ -z $id ]]; then
    jwt=$(jq -r '.tokens.id_token // empty' "$1" 2>/dev/null)
    if [[ $jwt == *.*.* ]]; then
      body=$(_b64url "$(cut -d. -f2 <<<"$jwt")")
      id=$(base64 -d <<<"$body" 2>/dev/null | jq -r '.email // .sub // empty' 2>/dev/null || true)
    fi
  fi
  printf '%s' "$id"
}
# True unless both files name an owner and the owners differ.
codex_same_login() { # live saved
  local a b; a=$(codex_identity "$1"); b=$(codex_identity "$2")
  [[ -z $a || -z $b || $a == "$b" ]]
}

# Put the chosen account's auth.json into the default Codex home so a plain
# `codex` and outside monitors read it. The outgoing account's live auth is
# saved first (Codex refreshes tokens in place). Only auth.json moves; config,
# sessions and history in the live home stay as they are.
swap_live_auth() { # name dir home
  local name="$1" dir="$2" home="$3"
  local live="${CODEX_HOME:-$HOME/.codex}" out odir ohome src
  out=$(active)
  if [[ -n $out && $out != "$name" && -f $live/auth.json ]]; then
    odir=$(account_dir "$out")
    local ref=""
    [[ -f $odir/auth.json ]] && ref="$odir/auth.json" || { ohome=$(home_of "$out"); [[ -f $ohome/auth.json ]] && ref="$ohome/auth.json"; }
    if [[ -n $ref ]] && ! codex_same_login "$live/auth.json" "$ref"; then
      echo "swapkin: warning: $live/auth.json is not $out's login; not saving it over $out's profile." >&2
    elif [[ -f $odir/codex.json ]]; then
      codex_copy_auth "$live/auth.json" "$odir/auth.json" \
        || die "could not save $out's login; nothing was switched"
      ohome=$(home_of "$out")
      if [[ -n $ohome && $ohome != "$live" && -d $ohome ]]; then
        codex_copy_auth "$live/auth.json" "$ohome/auth.json" || true
      fi
    fi
  fi
  if [[ -f $dir/auth.json ]]; then src="$dir/auth.json"
  elif [[ -f $home/auth.json ]]; then src="$home/auth.json"
  else return 0; fi # keyring-only login: nothing to copy
  [[ $src -ef $live/auth.json ]] && return 0
  mkdir -p "$live"
  codex_copy_auth "$src" "$live/auth.json" || die "could not write $live/auth.json"
}

p_env() { # name
  local home; home=$(home_of "$1")
  [[ -n $home ]] || return 0
  echo "CODEX_HOME=$home"
}

# base64url -> base64, padded.
_b64url() {
  local s pad
  s=$(tr '_-' '/+' <<<"$1")
  pad=$(( (4 - ${#s} % 4) % 4 ))
  while (( pad-- > 0 )); do s+="="; done
  printf '%s' "$s"
}

p_probe() { # name
  local name="$1" dir; dir=$(account_dir "$name")
  local home; home=$(home_of "$name")
  [[ -n $home && -d $home/sessions ]] || return 0
  local files; files=$(find "$home/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null | sort -r | head -5)
  [[ -n $files ]] || return 0

  local f line="" rl_file=""
  for f in $files; do
    line=$(tac "$f" 2>/dev/null | grep -m1 '"rate_limits"' || true)
    [[ -n $line ]] && { rl_file="$f"; break; }
  done
  [[ -n $line ]] || return 0

  local payload; payload=$(jq -c '.payload.rate_limits // empty' <<<"$line" 2>/dev/null) || return 0
  [[ -n $payload && $payload != null ]] || return 0
  local mtime; mtime=$(stat -c %Y "$rl_file")
  local updated_at; updated_at=$(date -u -d "@$mtime" +%Y-%m-%dT%H:%M:%SZ)

  local plan=""
  plan=$(jq -r '.plan_type // empty' <<<"$payload")
  if [[ -z $plan && -f $home/auth.json ]]; then
    local jwt; jwt=$(jq -r '.tokens.id_token // empty' "$home/auth.json" 2>/dev/null)
    if [[ -n $jwt ]]; then
      local body; body=$(_b64url "$(cut -d. -f2 <<<"$jwt")")
      plan=$(base64 -d <<<"$body" 2>/dev/null | jq -r '."https://api.openai.com/auth".chatgpt_plan_type // empty' 2>/dev/null || true)
    fi
  fi

  local limits='[]' key
  for key in primary secondary; do
    local node; node=$(jq -c --arg k "$key" '.[$k] // empty' <<<"$payload")
    [[ -n $node && $node != null ]] || continue
    local used_pct win resets_at resets_in iso=""
    IFS=$'\t' read -r used_pct win resets_at resets_in <<<"$(jq -r \
      '[(.used_percent // 0), (.window_minutes // 0), (.resets_at // ""), (.resets_in_seconds // "")] | @tsv' \
      <<<"$node")"
    if [[ -n $resets_at ]]; then
      iso=$(date -u -d "@$resets_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    elif [[ -n $resets_in ]]; then
      iso=$(date -u -d "@$((mtime + resets_in))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    fi
    local label
    if [[ $win == 300 ]]; then label="5h window"
    elif [[ $win == 10080 ]]; then label="Weekly"
    elif [[ $win == 43200 ]]; then label="Monthly (30-day)"
    elif (( win > 0 && win % 60 == 0 )); then label="$((win/60))h window"
    else label="${win}m window"; fi
    limits=$(jq -c --argjson limits "$limits" --arg label "$label" --argjson pct "$used_pct" --arg resets "$iso" \
      -n '$limits + [{label:$label, percent: ($pct/100), resetsAt:$resets}]')
  done

  jq -n --argjson limits "$limits" --arg plan "$plan" --arg updated "$updated_at" \
    '{limits:$limits, counts:[], tierLabel:$plan, note:"", updatedAt:$updated}' > "$dir/usage.json.tmp"
  mv "$dir/usage.json.tmp" "$dir/usage.json"
}

# The active account as a segment, same shape as Claude's. Codex has no custom
# status line to put it in; the README shows it in the terminal title instead.
p_statusline() {
  local name; name=$(active)
  [[ -n $name ]] || return 0
  local colour; colour=$(colour_of "$name")
  [[ $colour =~ ^#[0-9a-fA-F]{6}$ ]] || colour="#d97757"
  if [[ ${1:-} == --plain ]]; then
    printf '@%s' "$name"
    return
  fi
  printf '\033[38;2;%d;%d;%dm@%s\033[0m' \
    "$((16#${colour:1:2}))" "$((16#${colour:3:2}))" "$((16#${colour:5:2}))" "$name"
}

p_plan() { jq -r '.tierLabel // empty' "$(account_dir "$1")/usage.json" 2>/dev/null; }

# Auto-switch only hands over to a saved account that has a login on disk.
p_plausible_login() { local home; home=$(home_of "$1"); [[ -n $home && -f $home/auth.json ]]; }
