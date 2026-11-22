# shellcheck shell=bash
# shellcheck disable=SC2034  # P_* vars are read by the engine after sourcing this file
# Claude Code adapter. Moved out of the old single-provider bin/swapkin
# unchanged: behaviour, storage layout ($ACCOUNTS/<name>/, $ACCOUNTS/active)
# and every helper here are byte-for-byte what shipped before providers existed.
#
# Settings, sessions, skills, hooks and MCP logins stay where they are. A switch
# only swaps the Claude login (claudeAiOauth in .credentials.json) and the account
# profile (oauthAccount in .claude.json). Running sessions notice the new login on
# their next request, because Claude Code re-reads the file when its mtime changes.

P_ID=claude
P_NAME="Claude Code"
P_MODE=hot
P_CMD=claude
P_MARKER=oauth.json
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
P_STORE="$CONFIG_DIR/.credentials.json"
P_HOW="Switching updates the shared Claude Code login; open sessions notice it on their next request."
P_ADD_HINT="The first account is whatever is already signed in."

CREDS="$CONFIG_DIR/.credentials.json"
# Claude Code keeps .claude.json in $HOME unless CLAUDE_CONFIG_DIR moves it.
if [[ -n ${CLAUDE_CONFIG_DIR:-} ]]; then STATE="$CONFIG_DIR/.claude.json"; else STATE="$HOME/.claude.json"; fi

# A floating terminal starts from a bare environment, so a CLI installed by a
# version manager (mise, asdf, nvm, volta) is not on PATH yet. Find it anyway.
claude_bin() {
  local candidate
  if candidate=$(command -v claude 2>/dev/null); then echo "$candidate"; return; fi
  for candidate in "$HOME/.local/share/mise/shims/claude" "$HOME/.local/bin/claude" \
                   "$HOME/.claude/local/claude" "$HOME/.asdf/shims/claude" \
                   "$HOME/.volta/bin/claude" "/usr/local/bin/claude" "/usr/bin/claude"; do
    [[ -x $candidate ]] && { echo "$candidate"; return; }
  done
  candidate=$(bash -lc 'command -v claude' 2>/dev/null || true)
  [[ -n $candidate ]] && echo "$candidate"
}

p_installed() { [[ -n $(claude_bin) ]]; }
p_has_login() { [[ -f $HOME/.claude/.credentials.json ]]; }
p_sessions() { pgrep -x claude 2>/dev/null | wc -l; }

ICONS="$PROVIDERS_DIR/../../icons"

# What .claude.json keys belong to the account rather than to this machine.
# They carry the plan: which models it may use, its org defaults, its extra-usage
# state. Carried across with the login, or a Pro account keeps a Max account's
# answers until Claude Code refetches them.
ACCOUNT_KEYS='["oauthAccount","userID","modelAccessCache","orgModelDefaultCache","passesEligibilityCache","additionalModelCostsCache","additionalModelOptionsCache","additionalModelOptionsAnsweredAt","cachedExtraUsageDisabledReason","cachedUsageUtilization","groveConfigCache","penguinModeOrgEnabled","opusProMigrationComplete"]'
# Per-user experiment flags: never worth carrying, always worth dropping, since
# Claude Code refetches them for whoever is signed in.
VOLATILE_KEYS='["cachedStatsigGates","cachedExperimentData","cachedExperimentFeatures","cachedGrowthBookFeatures","cachedGrowthBookFeaturesAt","autoCompactWindowsCache"]'

# Who a token belongs to, asked of Anthropic's profile endpoint. Empty when it
# cannot be told (offline, expired, slow): callers then keep what they have.
token_uuid() { # access-token
  [[ -n $1 ]] || return 0
  curl -fsS --max-time 5 -H "Authorization: Bearer $1" -H "anthropic-beta: oauth-2025-04-20" \
    "${SWAPKIN_PROFILE_URL:-https://api.anthropic.com/api/oauth/profile}" 2>/dev/null \
    | jq -r '.account.uuid // empty' 2>/dev/null || true
}

# Copy a login out of a config dir into a profile.
# ~/.claude.json is shared by every open Claude Code session, and an older
# session rewrites it with ITS account. So oauthAccount (and the per-account
# keys with it) is only taken when it belongs to the token being saved. Not
# told (offline)? Take it only when it matches what the profile already holds.
store() { # name creds-file state-file
  local dir; dir=$(account_dir "$1")
  mkdir -p "$dir"
  jq -e '.claudeAiOauth.refreshToken' "$2" >/dev/null 2>&1 || die "no Claude login found in $2"
  jq '.claudeAiOauth' "$2" > "$dir/oauth.json.tmp"
  local owner live saved trust=0
  owner=$(token_uuid "$(jq -r '.claudeAiOauth.accessToken // empty' "$2" 2>/dev/null)")
  live=$(jq -r '.oauthAccount.accountUuid // empty' "$3" 2>/dev/null || true)
  saved=$(jq -r '.oauthAccount.accountUuid // empty' "$dir/account.json" 2>/dev/null || true)
  if [[ -n $owner ]]; then [[ $live == "$owner" ]] && trust=1
  else [[ -z $saved || $live == "$saved" ]] && trust=1; fi
  if (( trust )); then
    jq --argjson keys "$ACCOUNT_KEYS" 'with_entries(select(.key as $k | $keys | index($k)))' "$3" > "$dir/account.json.tmp"
    mv "$dir/account.json.tmp" "$dir/account.json"
  else
    auto_log "account mismatch: $1 saved profile kept, live ~/.claude.json holds another account (${live:-none})"
    [[ -f $dir/account.json ]] || echo '{}' > "$dir/account.json"
  fi
  mv "$dir/oauth.json.tmp" "$dir/oauth.json"
}

# Refresh tokens rotate, so the live login goes back to its profile before every switch.
p_save() {
  local name; name=$(active)
  [[ -n $name ]] || die "no active account yet; run: swapkin add <name>"
  store "$name" "$CREDS" "$STATE"
}

# A profile has to hold something that can actually be a login. Anything shorter
# is test data or a half-written file, and switching to it logs the machine out.
plausible_login() { # account
  local length dir; dir=$(account_dir "$1")
  length=$(jq -r '(.refreshToken // "") | length' "$dir/oauth.json" 2>/dev/null || echo 0)
  (( length >= 40 ))
}

p_use() {
  local name="$1" dir; dir=$(account_dir "$name")
  [[ -f $dir/oauth.json ]] || die "no saved login for '$name'"
  plausible_login "$name" || die "'$name' has no usable login; sign in again with: swapkin add $name"
  [[ -n $(active) ]] && p_save
  replace "$CREDS" '.claudeAiOauth = $o[0]' --slurpfile o "$dir/oauth.json"
  # Drop the outgoing account's per-user flags, then lay the incoming account's
  # own keys on top. Everything else in .claude.json — projects, history,
  # onboarding, this machine's ids — stays exactly as it was.
  # A saved profile whose oauthAccount belongs to another token is never merged.
  local owner mine; owner=$(token_uuid "$(jq -r '.accessToken // empty' "$dir/oauth.json" 2>/dev/null)")
  mine=$(jq -r '.oauthAccount.accountUuid // empty' "$dir/account.json" 2>/dev/null || true)
  if [[ -n $owner && -n $mine && $owner != "$mine" ]]; then
    auto_log "account mismatch: $name saved profile belongs to another account, not merged"
    # Drop the outgoing account's own keys too; Claude Code refetches them.
    echo '{}' > "$dir/account.use.json"
    replace "$STATE" 'with_entries(select(.key as $k | $keys | index($k) | not))' --argjson keys "$ACCOUNT_KEYS"
  else
    cp "$dir/account.json" "$dir/account.use.json"
  fi
  replace "$STATE" 'with_entries(select(.key as $k | $vol | index($k) | not)) * $a[0]' \
    --argjson vol "$VOLATILE_KEYS" --slurpfile a "$dir/account.use.json"
  rm -f "$dir/account.use.json"
  set_active "$name"
  echo "Active: $name"
}

# The newest throwaway folder that already holds a finished sign-in, if any.
pending_login() {
  local newest="" dir
  for dir in "$ACCOUNTS"/.login.*/; do
    [[ -f $dir/.credentials.json ]] || continue
    [[ -z $newest || $dir -nt $newest ]] && newest="$dir"
  done
  [[ -n $newest ]] && echo "${newest%/}"
  return 0
}

# The first account is whoever is signed in now. Later ones sign in inside a
# throwaway config dir, so the shared ~/.claude is never touched by the login.
p_add() {
  local name="${1:?usage: swapkin add <name>}"
  valid_name "$name"
  [[ -f $(account_dir "$name")/oauth.json ]] && die "'$name' already exists"

  if [[ -z $(profiles) ]]; then
    store "$name" "$CREDS" "$STATE"
    set_colour "$name" "$(next_colour "$name")"
    set_active "$name"
    echo "Saved the current login as '$name'."
    return
  fi

  # A sign-in that never reached this script still left its login on disk.
  # Offer it rather than asking the user to sign in twice.
  local pending; pending=$(pending_login || true)
  if [[ -n $pending ]]; then
    store "$name" "$pending/.credentials.json" "$pending/.claude.json"
    set_colour "$name" "$(next_colour "$name")"
    rm -rf "$pending"
    echo "Recovered the sign-in you already finished and saved it as '$name'."
    return
  fi

  # The trap fires after this function returns, so the folder it cleans up has
  # to outlive the local scope.
  LOGIN_DIR=$(mktemp -d "$ACCOUNTS/.login.XXXXXX")
  trap 'rm -rf "${LOGIN_DIR:-}"' EXIT
  local login="$LOGIN_DIR"
  # Carry the theme across so the throwaway session looks like the usual one.
  # Nothing about onboarding or login is copied: the sign-in flow must run intact.
  jq '{theme} | with_entries(select(.value != null))' "$STATE" > "$login/.claude.json"
  cat <<EOF
Claude Code opens in a throwaway config folder. Sign in with:

  /login

That is the whole job. This window closes by itself once the account is saved.
Your usual config, your sessions and your open Claude Code windows are untouched.

EOF

  local cli; cli=$(claude_bin)
  [[ -n $cli ]] || fail "cannot find the claude command. Open a terminal where 'claude' works and run: swapkin add $name"

  # Watch for the sign-in instead of asking the user to quit Claude Code: the
  # credentials file appears the moment /login succeeds. Saving it right then
  # also beats the throwaway session to its first token refresh, which would
  # rotate the token this profile just stored.
  CLAUDE_CONFIG_DIR="$login" "$cli" &
  local claude_pid=$!
  local waited=0
  while (( waited < 900 )); do
    if [[ -f $login/.credentials.json ]] && jq -e '.claudeAiOauth.refreshToken' "$login/.credentials.json" >/dev/null 2>&1; then
      sleep 1   # let Claude Code finish writing the account profile too
      store "$name" "$login/.credentials.json" "$login/.claude.json"
      set_colour "$name" "$(next_colour "$name")"
      kill "$claude_pid" 2>/dev/null || true
      wait "$claude_pid" 2>/dev/null || true
      echo
      echo "Saved '$name'. Pick it from the bar, or run: swapkin use $name"
      sleep 2
      return
    fi
    kill -0 "$claude_pid" 2>/dev/null || break
    sleep 1
    waited=$((waited + 1))
  done

  wait "$claude_pid" 2>/dev/null || true
  fail "no sign-in found, so nothing was saved. Run /login inside Claude Code."
}

# One account's limits, from its own saved login and its own cache, so several
# accounts can be probed at once without mixing anything up.
p_probe() { # account
  local dir; dir=$(account_dir "$1")
  mkdir -p "$dir/shadow" "$dir/cache"
  # Told to wait: do not ask again until then. The saved figures stay as they are.
  local until_ts; until_ts=$(cat "$dir/ratelimit.until" 2>/dev/null || echo 0)
  if [[ $until_ts =~ ^[0-9]+$ ]] && (( until_ts > $(date +%s) )); then
    run_log "probe rate limited for $1 until $(date -d "@$until_ts" +%H:%M), using figures from $(date -d "@$(stat -c %Y "$dir/usage.json" 2>/dev/null || echo 0)" +%H:%M)"
    return 0
  fi
  jq '{claudeAiOauth: .}' "$dir/oauth.json" > "$dir/shadow/.credentials.json"
  # Output goes to a file, not a $(...): a grandchild that outlives the tool
  # would hold the pipe open and block this probe, and the whole check, forever.
  local record
  CLAUDE_CONFIG_DIR="$dir/shadow" XDG_CACHE_HOME="$dir/cache" \
    timeout -k 2 20 omarchy-agent-usage-claude --limits-only --force >"$dir/probe.out" 2>/dev/null </dev/null || { rm -f "$dir/probe.out"; return 0; }
  record=$(<"$dir/probe.out"); rm -f "$dir/probe.out"
  # Anthropic rate-limits the usage endpoint. Remember that this account was
  # told so (the panel then says why, instead of asking for a new login).
  if jq -e '(.authHelpText // "") | test("rate limiting")' >/dev/null 2>&1 <<<"$record"; then
    jq -r '.authHelpText' <<<"$record" > "$dir/ratelimit"
    # "retry after 1260s": remember when, so no pass asks before then. 0s = unknown.
    local wait_s; wait_s=$(grep -oE 'retry after [0-9]+' "$dir/ratelimit" | grep -oE '[0-9]+$' || true)
    if [[ $wait_s =~ ^[0-9]+$ ]] && (( wait_s > 0 )); then echo $(( $(date +%s) + wait_s )) > "$dir/ratelimit.until"; else rm -f "$dir/ratelimit.until"; fi
    # The figures in a rate limited answer are local estimates, not Anthropic's:
    # keep the last real ones (and their time) instead of overwriting them.
    run_log "probe rate limited for $1, using figures from $(date -d "@$(stat -c %Y "$dir/usage.json" 2>/dev/null || echo 0)" +%H:%M)"
    return 0
  else
    rm -f "$dir/ratelimit" "$dir/ratelimit.until"
  fi
  jq -e '(.limits // []) | length > 0' >/dev/null 2>&1 <<<"$record" || return 0
  # The limits tool rebuilds a label from the rate-limit tier, which goes
  # stale on a rename. Use the plan name the CLI's profile got from the API.
  jq -c --arg tier "$(account_plan_name "$1")" '{limits, tierLabel: $tier, updatedAt}' <<<"$record" > "$dir/usage.json.tmp"
  mv "$dir/usage.json.tmp" "$dir/usage.json"
}

# Anthropic's profile names the plan; when it has none, keep the raw credential
# value. No name is built from a tier here.
account_plan_name() { # account
  local dir; dir=$(account_dir "$1")
  local name=""
  # The account's own saved profile first. ~/.claude.json is only trusted for the
  # active account when it is the same login: right after a switch it can still
  # hold the previous account's profile.
  name=$(jq -r '.oauthAccount.planDisplayName // empty' "$dir/account.json" 2>/dev/null || true)
  if [[ -z $name && $1 == "$(active)" && -f $STATE ]]; then
    local mine live
    mine=$(jq -r '.oauthAccount.accountUuid // empty' "$dir/account.json" 2>/dev/null || true)
    live=$(jq -r '.oauthAccount.accountUuid // empty' "$STATE" 2>/dev/null || true)
    if [[ -z $mine || $mine == "$live" ]]; then
      name=$(jq -r '.oauthAccount.planDisplayName // empty' "$STATE" 2>/dev/null || true)
    fi
  fi
  [[ -n $name ]] || name=$(jq -r '.subscriptionType // empty' "$dir/oauth.json" 2>/dev/null || true)
  [[ -n $name ]] || name=$(jq -r '.rateLimitTier // empty' "$dir/oauth.json" 2>/dev/null || true)
  printf '%s' "$name"
}

p_plan() { account_plan_name "$1"; }

p_plausible_login() { plausible_login "$1"; }

STATE_FILE="$ACCOUNTS/watch.json"

weekly_of() { # account
  jq -r '[.limits[]? | select((.label // "") | ascii_downcase | test("week"))][0].percent // -1' \
    "$(account_dir "$1")/usage.json" 2>/dev/null || echo -1
}

# The account with the most room left, ignoring the one passed in.
roomiest() { # account to ignore
  local best="" best_pct=2 name pct
  for name in $(profiles); do
    [[ $name == "$1" ]] && continue
    pct=$(weekly_of "$name")
    awk -v p="$pct" 'BEGIN{exit !(p >= 0)}' || continue
    if awk -v p="$pct" -v b="$best_pct" 'BEGIN{exit !(p < b)}'; then
      best="$name"
      best_pct="$pct"
    fi
  done
  echo "$best"
}



# One pass of the watchdog: refresh the figures, warn once per threshold, and
# hand over to another account when this one is spent. `check` always runs
# Claude through this entry point regardless of -p, then Codex (autoswitch.sh).
RUN_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/swapkin/check.log"
run_log() { # one start and one end line per pass, last 200 kept
  mkdir -p "$(dirname "$RUN_LOG")"
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" >> "$RUN_LOG"
  if (( $(wc -l < "$RUN_LOG") > 200 )); then tail -n 200 "$RUN_LOG" > "$RUN_LOG.tmp" && mv "$RUN_LOG.tmp" "$RUN_LOG"; fi
}

claude_check() {
  run_log "check start pid=$$"
  trap 'run_log "check end rc=$?"' EXIT
  cmd_usage
  local cur; cur=$(active)
  [[ -n $cur ]] || return 0
  auto_switch_run "$cur" && return 0
  local pct; pct=$(weekly_of "$cur")
  awk -v p="$pct" 'BEGIN{exit !(p >= 0)}' || return 0

  local warn_at; warn_at=$(setting alertAt 90)
  # Date only: the API restamps this to the current instant on every fetch,
  # so keying on the full value would treat each check() run as a new window
  # and re-notify every time instead of once per real reset.
  local reset; reset=$(jq -r '[.limits[]? | select((.label // "") | ascii_downcase | test("week"))][0].resetsAt // ""' "$(account_dir "$cur")/usage.json" 2>/dev/null | cut -c1-10)
  local last; last=$(jq -r --arg a "$cur" --arg r "$reset" '.[$a][$r] // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  local stage=0
  awk -v p="$pct" -v w="$warn_at" 'BEGIN{exit !(p * 100 >= w)}' && stage=1
  awk -v p="$pct" 'BEGIN{exit !(p >= 1)}' && stage=2
  (( stage > last )) || return 0

  local other; other=$(roomiest "$cur")
  # Never hand over to an account that cannot be verified: a real login, and
  # figures fresh enough to trust.
  if [[ -n $other ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$(account_dir "$other")/usage.json" 2>/dev/null || echo 0) ))
    if ! plausible_login "$other" || (( age > 7200 )); then other=""; fi
  fi
  if (( stage >= 1 )); then
    local pretty; pretty=$(awk -v p="$pct" 'BEGIN{printf "%d", p * 100}')
    if [[ -n $other ]]; then
      local free; free=$(awk -v p="$(weekly_of "$other")" 'BEGIN{printf "%d", (1 - p) * 100}')
      notify "$cur is at ${pretty}% of its week" "$other has ${free}% free. Switch from the bar, or press a in the panel." "$cur"
    else
      notify "$cur is at ${pretty}% of its week" "No other account has room right now." "$cur"
    fi
  fi

  local tmp; tmp=$(mktemp "$STATE_FILE.XXXXXX")
  jq -n --arg a "$cur" --arg r "$reset" --argjson s "$stage" --slurpfile old <(cat "$STATE_FILE" 2>/dev/null || echo '{}') \
    '($old[0] // {}) * {($a): {($r): $s}}' > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

RECORD="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage/claude.json"
PRICES="$PROVIDERS_DIR/../../prices.json"

# What today's tokens would have cost on the API. The collector reports today's
# tokens per model but not how they split between input, output and cache, so the
# split is taken from that model's all-time mix. An estimate, and labelled as one.
p_cost() {
  [[ -f $RECORD && -f $PRICES ]] || { echo '{"today":null}'; return; }
  jq -c --slurpfile prices "$PRICES" '
    ($prices[0].models // {}) as $rates
    | def rate($model): ($rates | to_entries | map(select(.key as $k | $model | startswith($k)))[0].value // null);
      (.modelUsage // {}) as $mix
    | [ (.todayTokensByModel // {}) | to_entries[]
        | . as $day
        | (rate($day.key)) as $r
        | ($mix[$day.key] // {}) as $m
        | (($m.inputTokens // 0) + ($m.outputTokens // 0)
           + ($m.cacheReadInputTokens // 0) + ($m.cacheCreationInputTokens // 0)) as $total
        | select($r != null and $total > 0)
        | ($day.value / $total) as $scale
        | ((($m.inputTokens // 0) * $scale * $r.input
            + ($m.outputTokens // 0) * $scale * $r.output
            + ($m.cacheReadInputTokens // 0) * $scale * $r.cacheRead
            + ($m.cacheCreationInputTokens // 0) * $scale * $r.cacheWrite) / 1000000) ]
      | add // 0
      | { today: (. * 100 | round / 100) }' "$RECORD"
}

# A ready-made segment for Claude Code's status line: the active account in its
# own colour. Print it from your status line command.
p_statusline() {
  sl_enabled claude || return 0   # the panel's Off: print nothing, however it is wired
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

p_statusline_install()   { sl_install claude; }
p_statusline_uninstall() { sl_uninstall; }
p_statusline_on()        { sl_on claude; }
p_statusline_off()       { sl_off claude; }
p_statusline_status()    { sl_status claude; }

p_status() {
  local name; name=$(active)
  [[ -n $name ]] || { echo "No accounts yet. Run: swapkin add <name>"; return; }
  printf '%s · %s\n' "$name" "$(jq -r '.claudeAiOauth.subscriptionType // "?"' "$CREDS")"
}
