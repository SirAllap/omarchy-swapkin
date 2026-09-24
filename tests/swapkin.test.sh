#!/usr/bin/env bash
# Run: bash tests/swapkin.test.sh
#
# No real HOME, SWAPKIN_DIR, gh config or network is ever touched: every test
# below builds its own temp HOME/SWAPKIN_DIR/XDG dirs and puts stub claude/
# codex/gh commands on PATH first.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(dirname "$HERE")"
SWAPKIN="$ROOT/bin/swapkin"
FIXTURES="$HERE/fixtures"

PASS=0
FAIL=0
ALL_OUTPUT_LOG="$(mktemp)"
trap 'rm -f "$ALL_OUTPUT_LOG"' EXIT

ok() { PASS=$((PASS+1)); echo "  ok - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  NOT OK - $1"; }

assert_eq() { # desc expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi
}
assert_true() { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$*"; fi; }
assert_contains() { # desc haystack needle
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (missing [$3])"; fi
}
assert_not_contains() { # desc haystack needle
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (found forbidden [$3])"; fi
}

# Every real swapkin invocation in the suite goes through here, so its output
# also lands in ALL_OUTPUT_LOG for the final "no fixture token leaked" check.
sk() { # env-assignments... -- args...
  local out
  out=$("$@" 2>&1)
  echo "$out" >> "$ALL_OUTPUT_LOG"
  printf '%s' "$out"
}

# --- a fresh sandbox: temp HOME, SWAPKIN_DIR, XDG dirs, stub PATH ---
STUBS="$(mktemp -d)"
mk_stub() { # name body
  cat > "$STUBS/$1" <<EOF
#!/usr/bin/env bash
$2
EOF
  chmod +x "$STUBS/$1"
}

sandbox() {
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/home" "$dir/data" "$dir/config" "$dir/state" "$dir/cache"
  echo "$dir"
}

# ============================================================ 1. claude use ==
echo "1. claude use saves the live login back before switching"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" CLAUDE_CONFIG_DIR="$S/home/.claude" \
       XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" \
       PATH="$STUBS:$PATH" SWAPKIN_DEMO=0
unset SWAPKIN_PROVIDER
mkdir -p "$CLAUDE_CONFIG_DIR"
LIVE_TOKEN="live-token-for-work-AAAAAAAAAAAAAAAAAAAAAAAAAAAA"
STALE_TOKEN="stale-token-for-work-BBBBBBBBBBBBBBBBBBBBBBBBBBBB"
PERSONAL_TOKEN="token-for-personal-CCCCCCCCCCCCCCCCCCCCCCCCCCCC"
jq -n --arg t "$LIVE_TOKEN" '{claudeAiOauth:{refreshToken:$t, subscriptionType:"max"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
jq -n '{theme:"dark"}' > "$CLAUDE_CONFIG_DIR/.claude.json"
mkdir -p "$SWAPKIN_DIR/work" "$SWAPKIN_DIR/personal"
jq -n --arg t "$STALE_TOKEN" '{refreshToken:$t, subscriptionType:"max"}' > "$SWAPKIN_DIR/work/oauth.json"
echo '{}' > "$SWAPKIN_DIR/work/account.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/work/meta.json"
jq -n --arg t "$PERSONAL_TOKEN" '{refreshToken:$t, subscriptionType:"pro"}' > "$SWAPKIN_DIR/personal/oauth.json"
echo '{}' > "$SWAPKIN_DIR/personal/account.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/personal/meta.json"
echo work > "$SWAPKIN_DIR/active"

out=$(sk "$SWAPKIN" use personal)
assert_contains "use prints the new active account" "$out" "Active: personal"
saved_back=$(jq -r .refreshToken "$SWAPKIN_DIR/work/oauth.json")
assert_eq "outgoing account's live login was saved back before the switch" "$LIVE_TOKEN" "$saved_back"
live_now=$(jq -r .claudeAiOauth.refreshToken "$CLAUDE_CONFIG_DIR/.credentials.json")
assert_eq "live credentials now hold the incoming account's token" "$PERSONAL_TOKEN" "$live_now"
assert_eq "active pointer updated" "personal" "$(cat "$SWAPKIN_DIR/active")"

# ======================================================= 2. codex writes no auth.json ==
echo "2. codex use writes no auth.json anywhere"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
unset CLAUDE_CONFIG_DIR
mkdir -p "$S/codex-home-a" "$S/codex-home-b"
echo '{"tokens":{"id_token":"x"}}' > "$S/codex-home-a/auth.json"
echo '{"tokens":{"id_token":"x"}}' > "$S/codex-home-b/auth.json"
before_a=$(md5sum "$S/codex-home-a/auth.json" | cut -d' ' -f1)
before_b=$(md5sum "$S/codex-home-b/auth.json" | cut -d' ' -f1)
mkdir -p "$SWAPKIN_DIR/providers/codex/work" "$SWAPKIN_DIR/providers/codex/side-project"
jq -n --arg h "$S/codex-home-a" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/work/codex.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/codex/work/meta.json"
jq -n --arg h "$S/codex-home-b" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/side-project/codex.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/providers/codex/side-project/meta.json"
echo work > "$SWAPKIN_DIR/providers/codex/active"

before_count=$(find "$S" -name auth.json | wc -l)
out=$(sk "$SWAPKIN" -p codex use side-project)
assert_contains "codex use reports the new active account" "$out" "side-project"
after_count=$(find "$S" -name auth.json | wc -l)
assert_eq "no new auth.json files appeared anywhere under the sandbox" "$before_count" "$after_count"
assert_eq "codex-home-a/auth.json untouched" "$before_a" "$(md5sum "$S/codex-home-a/auth.json" | cut -d' ' -f1)"
assert_eq "codex-home-b/auth.json untouched" "$before_b" "$(md5sum "$S/codex-home-b/auth.json" | cut -d' ' -f1)"
assert_eq "active pointer switched" "side-project" "$(cat "$SWAPKIN_DIR/providers/codex/active")"

# ==================================================== 3. codex probe: new + old fields ==
echo "3. codex probe parses a rollout fixture (new and old reset fields)"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$S/home-new/sessions" "$S/home-old/sessions"
cp "$FIXTURES/rollout-new.jsonl" "$S/home-new/sessions/rollout-001.jsonl"
cp "$FIXTURES/rollout-old.jsonl" "$S/home-old/sessions/rollout-001.jsonl"
mkdir -p "$SWAPKIN_DIR/providers/codex/newfmt" "$SWAPKIN_DIR/providers/codex/oldfmt"
jq -n --arg h "$S/home-new" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/newfmt/codex.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/codex/newfmt/meta.json"
jq -n --arg h "$S/home-old" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/oldfmt/codex.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/providers/codex/oldfmt/meta.json"

sk "$SWAPKIN" -p codex usage >/dev/null
newfmt_label=$(jq -r '.limits[0].label' "$SWAPKIN_DIR/providers/codex/newfmt/usage.json" 2>/dev/null)
newfmt_pct=$(jq -r '.limits[0].percent' "$SWAPKIN_DIR/providers/codex/newfmt/usage.json" 2>/dev/null)
newfmt_weekly_label=$(jq -r '.limits[1].label' "$SWAPKIN_DIR/providers/codex/newfmt/usage.json" 2>/dev/null)
newfmt_resets=$(jq -r '.limits[0].resetsAt' "$SWAPKIN_DIR/providers/codex/newfmt/usage.json" 2>/dev/null)
assert_eq "new-format: 300min window labelled '5h window'" "5h window" "$newfmt_label"
assert_eq "new-format: percent converted from used_percent" "0.42" "$newfmt_pct"
assert_eq "new-format: 10080min window labelled 'Weekly'" "Weekly" "$newfmt_weekly_label"
assert_contains "new-format: resets_at (unix seconds) turned into ISO" "$newfmt_resets" "T"

oldfmt_label=$(jq -r '.limits[0].label' "$SWAPKIN_DIR/providers/codex/oldfmt/usage.json" 2>/dev/null)
oldfmt_pct=$(jq -r '.limits[0].percent' "$SWAPKIN_DIR/providers/codex/oldfmt/usage.json" 2>/dev/null)
oldfmt_resets=$(jq -r '.limits[0].resetsAt' "$SWAPKIN_DIR/providers/codex/oldfmt/usage.json" 2>/dev/null)
assert_eq "old-format: 300min window labelled '5h window'" "5h window" "$oldfmt_label"
assert_eq "old-format: percent converted from used_percent" "0.09" "$oldfmt_pct"
assert_contains "old-format: resets_in_seconds turned into ISO" "$oldfmt_resets" "T"

# ======================================================= 9. providers --json shape ==
echo "9. providers --json output validates against the documented shape"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH" SWAPKIN_DEMO=0
unset SWAPKIN_DEMO_FILE
mkdir -p "$SWAPKIN_DIR/work"
echo '{"refreshToken":"'"$(printf 'x%.0s' {1..40})"'","subscriptionType":"max"}' > "$SWAPKIN_DIR/work/oauth.json"
echo '{}' > "$SWAPKIN_DIR/work/account.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/work/meta.json"
echo work > "$SWAPKIN_DIR/active"

out=$(sk "$SWAPKIN" providers --json)
shape_ok=$(jq -e '
  (.demo == false) and
  (.providers | type == "array") and
  (.providers | all(
    (has("id") and has("name") and has("mode") and has("modeLabel") and has("modeWords")
     and has("store") and has("how") and has("addHint") and has("installed") and has("sessions") and has("accounts"))
    and (.mode as $m | ["hot","cold","never"] | index($m) != null)
    and (.accounts | type == "array")
    and (.accounts | all(has("name") and has("active") and has("colour") and has("plan") and has("age")))
  ))
' <<<"$out" >/dev/null 2>&1 && echo yes || echo no)
assert_eq "providers --json matches the documented shape" "yes" "$shape_ok"
assert_contains "the claude provider with its saved account is present" "$out" '"id":"claude"'

# ==================================== 11. H2: remove providers / path traversal ==
echo "11. remove providers is rejected; path traversal in remove is rejected"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" CLAUDE_CONFIG_DIR="$S/home/.claude" \
       XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" \
       PATH="$STUBS:$PATH"
mkdir -p "$SWAPKIN_DIR/providers/codex/other"
jq -n --arg h "$S/codex-home" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/other/codex.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/codex/other/meta.json"

out=$("$SWAPKIN" -p claude remove providers 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc" -ne 0 ]
assert_contains "'providers' is rejected as an account name" "$out" "reserved"
assert_true [ -d "$SWAPKIN_DIR/providers/codex/other" ]

out=$("$SWAPKIN" -p codex remove '../x' 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc" -ne 0 ]
assert_contains "path traversal in remove is rejected" "$out" "account names use"

# ============================================ 13. M2: malformed usage.json ==
echo "13. a non-object usage.json never breaks providers --json / list --json"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" CLAUDE_CONFIG_DIR="$S/home/.claude" \
       XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" \
       PATH="$STUBS:$PATH" SWAPKIN_DEMO=0
mkdir -p "$CLAUDE_CONFIG_DIR" "$SWAPKIN_DIR/work"
echo '{"refreshToken":"'"$(printf 'x%.0s' {1..40})"'","subscriptionType":"max"}' > "$SWAPKIN_DIR/work/oauth.json"
echo '{}' > "$SWAPKIN_DIR/work/account.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/work/meta.json"
echo '[1,2,3]' > "$SWAPKIN_DIR/work/usage.json"
echo work > "$SWAPKIN_DIR/active"

json_valid() { printf '%s' "$1" | jq -e . >/dev/null 2>&1; }

out=$("$SWAPKIN" providers --json 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_eq "providers --json still exits 0 with a malformed usage.json on disk" 0 "$rc"
assert_true json_valid "$out"
assert_contains "claude is still present in providers --json" "$out" '"id":"claude"'

out2=$("$SWAPKIN" list --json 2>&1); rc2=$?
echo "$out2" >> "$ALL_OUTPUT_LOG"
assert_eq "list --json still exits 0 with a malformed usage.json on disk" 0 "$rc2"
assert_true json_valid "$out2"

# ============================================== 14. M3: codex 'Not logged in' ==
echo "14. codex add refuses on 'Not logged in'; accepts a keyring-only login for add and use"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$S/codex-home-notloggedin" "$S/codex-home-keyring"
mk_stub codex "
case \"\$1 \$2\" in
  'login status')
    case \"\$CODEX_HOME\" in
      *codex-home-notloggedin) echo 'Not logged in'; exit 1 ;;
      *codex-home-keyring) echo 'Logged in using ChatGPT'; exit 0 ;;
    esac ;;
esac
"
out=$(CODEX_HOME="$S/codex-home-notloggedin" "$SWAPKIN" -p codex add notloggedin 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc" -ne 0 ]
assert_contains "'Not logged in' is refused, not accepted as a substring match" "$out" "no Codex login found"

out2=$(CODEX_HOME="$S/codex-home-keyring" "$SWAPKIN" -p codex add keyringacct 2>&1); rc2=$?
echo "$out2" >> "$ALL_OUTPUT_LOG"
assert_eq "a keyring-only login (no auth.json) is accepted by add" 0 "$rc2"
mkdir -p "$SWAPKIN_DIR/providers/codex/other"
jq -n --arg h "$S/codex-other-home" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/other/codex.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/providers/codex/other/meta.json"
echo other > "$SWAPKIN_DIR/providers/codex/active"
out3=$(CODEX_HOME="$S/codex-home-keyring" "$SWAPKIN" -p codex use keyringacct 2>&1); rc3=$?
echo "$out3" >> "$ALL_OUTPUT_LOG"
assert_eq "the same keyring-only login is accepted by use too, without auth.json" 0 "$rc3"

# ==================================================== 15. M8: run -- passthrough ==
echo "15. run -- passes every following argument to the child untouched, including -p"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
CODEX_ARGV_LOG="$S/codex-argv.log"
mk_stub codex "echo \"\$@\" > \"$CODEX_ARGV_LOG\""
mkdir -p "$SWAPKIN_DIR/providers/codex/work"
jq -n --arg h "$S/codex-home" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/work/codex.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/codex/work/meta.json"
echo work > "$SWAPKIN_DIR/providers/codex/active"

sk "$SWAPKIN" run codex -- -p myprofile exec hi >/dev/null
argv=$(cat "$CODEX_ARGV_LOG" 2>/dev/null)
assert_eq "codex's own -p reaches it unchanged" "-p myprofile exec hi" "$argv"

# ============================================ 17. M5: cold remove vs a live process ==
echo "17. codex remove refuses while a running process holds that CODEX_HOME open"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$S/codex-home-busy" "$S/codex-home-current"
mkdir -p "$SWAPKIN_DIR/providers/codex/busy" "$SWAPKIN_DIR/providers/codex/current"
jq -n --arg h "$S/codex-home-busy" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/busy/codex.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/codex/busy/meta.json"
jq -n --arg h "$S/codex-home-current" '{home:$h}' > "$SWAPKIN_DIR/providers/codex/current/codex.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/providers/codex/current/meta.json"
echo current > "$SWAPKIN_DIR/providers/codex/active"

CODEX_HOME="$S/codex-home-busy" sleep 30 &
BUSY_PID=$!
sleep 0.3

out=$("$SWAPKIN" -p codex remove busy 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc" -ne 0 ]
assert_contains "remove refuses while a running process still holds that CODEX_HOME" "$out" "in use"
assert_true [ -d "$SWAPKIN_DIR/providers/codex/busy" ]

kill "$BUSY_PID" 2>/dev/null; wait "$BUSY_PID" 2>/dev/null

out2=$("$SWAPKIN" -p codex remove busy 2>&1); rc2=$?
echo "$out2" >> "$ALL_OUTPUT_LOG"
assert_eq "remove succeeds once no process holds that CODEX_HOME any more" 0 "$rc2"

# ==================================== 18. M7: watchdog auto-switch takes the lock ==
echo "18. the watchdog's auto-switch waits for \$ACCOUNTS/.lock instead of racing a concurrent use"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" CLAUDE_CONFIG_DIR="$S/home/.claude" \
       XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" \
       PATH="$STUBS:$PATH" SWAPKIN_DEMO=0
mkdir -p "$CLAUDE_CONFIG_DIR"
jq -n '{claudeAiOauth:{refreshToken:"'"$(printf 'x%.0s' {1..40})"'", subscriptionType:"max"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
jq -n '{theme:"dark"}' > "$CLAUDE_CONFIG_DIR/.claude.json"
mkdir -p "$SWAPKIN_DIR/spent" "$SWAPKIN_DIR/roomy"
echo '{"refreshToken":"'"$(printf 'x%.0s' {1..40})"'","subscriptionType":"max"}' > "$SWAPKIN_DIR/spent/oauth.json"
echo '{}' > "$SWAPKIN_DIR/spent/account.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/spent/meta.json"
jq -n '{limits:[{label:"Weekly",percent:1.0}]}' > "$SWAPKIN_DIR/spent/usage.json"
echo '{"refreshToken":"'"$(printf 'y%.0s' {1..40})"'","subscriptionType":"max"}' > "$SWAPKIN_DIR/roomy/oauth.json"
echo '{}' > "$SWAPKIN_DIR/roomy/account.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/roomy/meta.json"
jq -n '{limits:[{label:"Weekly",percent:0.1}]}' > "$SWAPKIN_DIR/roomy/usage.json"
echo spent > "$SWAPKIN_DIR/active"
jq -n '{autoSwitch:true, alertAt:90}' > "$SWAPKIN_DIR/config.json"
# No omarchy-agent-usage-claude stub on PATH: cmd_usage's probe finds nothing
# to run and leaves the usage.json files above exactly as seeded.

( exec 9>"$SWAPKIN_DIR/.lock"; flock 9; sleep 3 ) &
LOCK_PID=$!
sleep 0.3

start=$(date +%s)
out=$(sk "$SWAPKIN" check)
elapsed=$(( $(date +%s) - start ))
wait "$LOCK_PID" 2>/dev/null

assert_true [ "$elapsed" -ge 2 ]
assert_eq "auto-switch only lands once the lock is free" "roomy" "$(cat "$SWAPKIN_DIR/active")"

