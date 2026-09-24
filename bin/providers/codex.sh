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
P_HOW="New Codex sessions use the switched account; sessions already running keep theirs. Point a shell at one with: eval \"\$(swapkin env codex)\"."
P_ADD_HINT="The first account is whatever CODEX_HOME is already signed into."

p_installed() { [[ -n $(tool_bin codex) ]]; }
p_sessions() { pgrep -x codex 2>/dev/null | wc -l; }

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
  CODEX_HOME="$home" "$cli" login -c 'cli_auth_credentials_store="file"' || true
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
  # auth.json on disk is enough, but a keyring-only login that still reports
  # logged in (M3) must be accepted too — don't require the file to exist.
  [[ -f $home/auth.json ]] || codex_logged_in "$home" \
    || die "'$name' has no usable login; sign in again with: swapkin -p codex add $name"
  set_active "$name"
  echo "New Codex sessions use $name. Open ones keep their account. Run: eval \"\$(swapkin env codex)\""
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
    elif (( win > 0 && win % 60 == 0 )); then label="$((win/60))h window"
    else label="${win}m window"; fi
    limits=$(jq -c --argjson limits "$limits" --arg label "$label" --argjson pct "$used_pct" --arg resets "$iso" \
      -n '$limits + [{label:$label, percent: ($pct/100), resetsAt:$resets}]')
  done

  jq -n --argjson limits "$limits" --arg plan "$plan" --arg updated "$updated_at" \
    '{limits:$limits, counts:[], tierLabel:$plan, note:"", updatedAt:$updated}' > "$dir/usage.json.tmp"
  mv "$dir/usage.json.tmp" "$dir/usage.json"
}

p_plan() { jq -r '.tierLabel // empty' "$(account_dir "$1")/usage.json" 2>/dev/null; }
