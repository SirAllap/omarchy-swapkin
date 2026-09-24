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

# ================================================ 4. copilot probe + no token in argv ==
echo "4. copilot probe parses a fixture and never puts the token in argv"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
GH_ARGV_LOG="$S/gh-argv.log"; : > "$GH_ARGV_LOG"
GH_SECRET_TOKEN="ghs_SENTINEL_NEVER_IN_ARGV_0000000000"
mk_stub gh "
ARGV_LOG=\"$GH_ARGV_LOG\"
echo \"\$@\" >> \"\$ARGV_LOG\"
case \"\$1\" in
  auth)
    case \"\$2\" in
      status) cat '$FIXTURES/gh-auth-status.json' ;;
      token) echo '$GH_SECRET_TOKEN' ;;
      switch) exit 0 ;;
    esac ;;
  api) cat '$FIXTURES/copilot-user.json' ;;
esac
"
mkdir -p "$SWAPKIN_DIR/providers/copilot/work"
jq -n '{user:"octo-work"}' > "$SWAPKIN_DIR/providers/copilot/work/copilot.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/copilot/work/meta.json"
echo work > "$SWAPKIN_DIR/providers/copilot/active"

sk "$SWAPKIN" -p copilot usage >/dev/null
plan=$(jq -r .tierLabel "$SWAPKIN_DIR/providers/copilot/work/usage.json" 2>/dev/null)
premium_pct=$(jq -r '.limits[0].percent' "$SWAPKIN_DIR/providers/copilot/work/usage.json" 2>/dev/null)
chat_count=$(jq -r '.counts[] | select(.label=="Chat") | .value' "$SWAPKIN_DIR/providers/copilot/work/usage.json" 2>/dev/null)
assert_eq "plan mapped from access_type_sku (individual -> Pro)" "Pro" "$plan"
assert_eq "premium requests percent = used/entitlement" "0.62" "$premium_pct"
assert_eq "unlimited quota becomes a count, not a percent" "unlimited" "$chat_count"
argv_content=$(cat "$GH_ARGV_LOG")
assert_not_contains "gh's argv log never contains the token" "$argv_content" "$GH_SECRET_TOKEN"

# ==================================================== 5. custom hot save-then-swap ==
echo "5. custom hot saves back then swaps"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$XDG_CONFIG_HOME/swapkin" "$HOME/.acme"
cat > "$XDG_CONFIG_HOME/swapkin/providers.json" <<JSON
{"providers":[{"id":"acme","name":"Acme CLI","command":"acme","mode":"hot","loginFiles":["~/.acme/session.json"]}]}
JSON
chmod 600 "$XDG_CONFIG_HOME/swapkin/providers.json"
echo '{"session":"work-session-live"}' > "$HOME/.acme/session.json"
mkdir -p "$SWAPKIN_DIR/providers/acme/work/files" "$SWAPKIN_DIR/providers/acme/side-project/files"
echo '{"session":"work-session-live"}' > "$SWAPKIN_DIR/providers/acme/work/files/0"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/acme/work/meta.json"
echo '{"mode":"hot"}' > "$SWAPKIN_DIR/providers/acme/work/custom.json"
echo '{"session":"side-project-session"}' > "$SWAPKIN_DIR/providers/acme/side-project/files/0"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/providers/acme/side-project/meta.json"
echo '{"mode":"hot"}' > "$SWAPKIN_DIR/providers/acme/side-project/custom.json"
echo work > "$SWAPKIN_DIR/providers/acme/active"
echo '{"session":"changed-since-add"}' > "$HOME/.acme/session.json"

out=$(sk "$SWAPKIN" -p acme use side-project)
assert_contains "custom hot use reports the new active account" "$out" "Active: side-project"
saved=$(cat "$SWAPKIN_DIR/providers/acme/work/files/0")
assert_eq "outgoing account's live file saved back before swap" '{"session":"changed-since-add"}' "$saved"
live=$(cat "$HOME/.acme/session.json")
assert_eq "live file replaced with incoming account's saved copy" '{"session":"side-project-session"}' "$live"

# =========================================================== 6. custom cold env ==
echo "6. custom cold env"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$XDG_CONFIG_HOME/swapkin"
cat > "$XDG_CONFIG_HOME/swapkin/providers.json" <<JSON
{"providers":[{"id":"othertool","name":"Other Tool","command":"othertool","mode":"cold","homeEnv":"OTHER_HOME","defaultHome":"~/.other"}]}
JSON
chmod 600 "$XDG_CONFIG_HOME/swapkin/providers.json"
mkdir -p "$SWAPKIN_DIR/providers/othertool/side-project"
jq -n --arg h "$S/other-home" '{mode:"cold", home:$h}' > "$SWAPKIN_DIR/providers/othertool/side-project/custom.json"
jq -n '{colour:"#8fb572"}' > "$SWAPKIN_DIR/providers/othertool/side-project/meta.json"
echo side-project > "$SWAPKIN_DIR/providers/othertool/active"

out=$(sk "$SWAPKIN" env othertool)
assert_contains "env prints export OTHER_HOME=..." "$out" "export OTHER_HOME="
assert_contains "env points at the account's own home" "$out" "$S/other-home"

# =========================================== 7. unsafe custom config is ignored ==
echo "7. unsafe custom config file is ignored with a stderr warning"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$XDG_CONFIG_HOME/swapkin"
cat > "$XDG_CONFIG_HOME/swapkin/providers.json" <<JSON
{"providers":[{"id":"unsafe","name":"Unsafe","command":"unsafe","mode":"hot","loginFiles":[]}]}
JSON
chmod 666 "$XDG_CONFIG_HOME/swapkin/providers.json"

out=$("$SWAPKIN" providers --json 2>"$S/stderr.log")
echo "$out" >> "$ALL_OUTPUT_LOG"
cat "$S/stderr.log" >> "$ALL_OUTPUT_LOG"
assert_contains "a warning is printed to stderr" "$(cat "$S/stderr.log")" "ignoring"
assert_not_contains "the unsafe provider is not in the output" "$out" '"id":"unsafe"'

# ============================================ 8. demo mode: sentinel HOME untouched ==
echo "8. demo mode leaves a sentinel HOME untouched and never prints sentinel token text"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH" \
       SWAPKIN_DEMO=1 SWAPKIN_DEMO_FILE="$FIXTURES/demo-providers.json"
mkdir -p "$HOME/.claude"
SENTINEL_TOKEN="SENTINEL-REAL-REFRESH-TOKEN-DO-NOT-TOUCH-0000000000"
jq -n --arg t "$SENTINEL_TOKEN" '{claudeAiOauth:{refreshToken:$t, subscriptionType:"max"}}' > "$HOME/.claude/.credentials.json"
before_sum=$(md5sum "$HOME/.claude/.credentials.json" | cut -d' ' -f1)
before_tree=$(find "$HOME" -type f | sort)

demo_out=""
for args in "providers --json" "list --json" "status" "statusline" "cost" \
            "use personal" "add personal" "remove personal" "save" "usage" "check" \
            "env" "-p codex run codex"; do
  # shellcheck disable=SC2086
  demo_out+=$(sk "$SWAPKIN" $args)
  demo_out+=$'\n'
done

after_sum=$(md5sum "$HOME/.claude/.credentials.json" | cut -d' ' -f1)
after_tree=$(find "$HOME" -type f | sort)
assert_eq "sentinel credentials file byte-identical after every demo command" "$before_sum" "$after_sum"
assert_eq "no files created or removed under the sentinel HOME" "$before_tree" "$after_tree"
assert_not_contains "no demo output contains the sentinel token" "$demo_out" "$SENTINEL_TOKEN"
assert_contains "write commands say demo mode, nothing changed" "$demo_out" "demo mode, nothing changed"

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

# ============================================= 10. H1: custom hot add reorders ==
echo "10. custom hot add saves the active account back FIRST, then waits for a new sign-in"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$XDG_CONFIG_HOME/swapkin" "$HOME/.acme"
cat > "$XDG_CONFIG_HOME/swapkin/providers.json" <<JSON
{"providers":[{"id":"acme","name":"Acme CLI","command":"acme","mode":"hot","loginFiles":["~/.acme/session.json"]}]}
JSON
chmod 600 "$XDG_CONFIG_HOME/swapkin/providers.json"
mkdir -p "$SWAPKIN_DIR/providers/acme/work/files"
echo '{"session":"work-session-STALE"}' > "$SWAPKIN_DIR/providers/acme/work/files/0"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/acme/work/meta.json"
echo '{"mode":"hot"}' > "$SWAPKIN_DIR/providers/acme/work/custom.json"
echo work > "$SWAPKIN_DIR/providers/acme/active"
# The live file when `add` starts: work's real, current login (H1's bug: the
# old code copied THIS into work's profile only after account B had already
# signed in and overwritten it, losing work's login for good).
echo '{"session":"work-session-LIVE"}' > "$HOME/.acme/session.json"

"$SWAPKIN" -p acme add second >"$S/add-out.log" 2>&1 &
ADD_PID=$!
sleep 2
# Simulate signing in as the second account: the live file changes.
echo '{"session":"second-session-live"}' > "$HOME/.acme/session.json"
wait "$ADD_PID"; add_rc=$?
add_out=$(cat "$S/add-out.log")
echo "$add_out" >> "$ALL_OUTPUT_LOG"
assert_eq "add exits 0 once the sign-in is picked up" 0 "$add_rc"
work_saved=$(cat "$SWAPKIN_DIR/providers/acme/work/files/0")
assert_eq "work's profile holds its OWN live login, saved back before asking to sign in" \
  '{"session":"work-session-LIVE"}' "$work_saved"
second_saved=$(cat "$SWAPKIN_DIR/providers/acme/second/files/0")
assert_eq "second's profile holds the NEW sign-in, not work's" \
  '{"session":"second-session-live"}' "$second_saved"
assert_eq "second becomes active" "second" "$(cat "$SWAPKIN_DIR/providers/acme/active")"

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

# ========================================= 12. M1: custom hot use, partial swap ==
echo "12. custom hot use refuses (and changes nothing) when a saved copy or a live file is missing"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$XDG_CONFIG_HOME/swapkin" "$HOME/.acme2"
cat > "$XDG_CONFIG_HOME/swapkin/providers.json" <<JSON
{"providers":[{"id":"acme2","name":"Acme2","command":"acme2","mode":"hot","loginFiles":["~/.acme2/a.json","~/.acme2/b.json"]}]}
JSON
chmod 600 "$XDG_CONFIG_HOME/swapkin/providers.json"
echo '{"f":"a-live"}' > "$HOME/.acme2/a.json"
echo '{"f":"b-live"}' > "$HOME/.acme2/b.json"
mkdir -p "$SWAPKIN_DIR/providers/acme2/work/files" "$SWAPKIN_DIR/providers/acme2/broken/files"
echo '{"f":"a-saved-work"}' > "$SWAPKIN_DIR/providers/acme2/work/files/0"
echo '{"f":"b-saved-work"}' > "$SWAPKIN_DIR/providers/acme2/work/files/1"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/acme2/work/meta.json"
echo '{"mode":"hot"}' > "$SWAPKIN_DIR/providers/acme2/work/custom.json"
# 'broken' is missing its saved copy of file index 1 (b.json).
echo '{"f":"a-saved-broken"}' > "$SWAPKIN_DIR/providers/acme2/broken/files/0"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/providers/acme2/broken/meta.json"
echo '{"mode":"hot"}' > "$SWAPKIN_DIR/providers/acme2/broken/custom.json"
echo work > "$SWAPKIN_DIR/providers/acme2/active"

out=$("$SWAPKIN" -p acme2 use broken 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc" -ne 0 ]
assert_contains "use refuses when a saved copy is missing" "$out" "no saved copy"
a_live=$(cat "$HOME/.acme2/a.json")
assert_eq "file 0 (checked first) was NOT swapped before the missing file 1 was found" '{"f":"a-live"}' "$a_live"
assert_eq "active pointer unchanged on refusal" "work" "$(cat "$SWAPKIN_DIR/providers/acme2/active")"

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

# ============================================ 16. M9: copilot active from gh ==
echo "16. copilot's active account follows gh's real login, and use always calls gh auth switch"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
GH_SWITCH_LOG="$S/gh-switch.log"; : > "$GH_SWITCH_LOG"
mk_stub gh "
case \"\$1 \$2\" in
  'auth status') cat '$FIXTURES/gh-auth-status.json' ;;
  'auth switch') echo \"\$@\" >> \"$GH_SWITCH_LOG\"; exit 0 ;;
esac
"
mkdir -p "$SWAPKIN_DIR/providers/copilot/work" "$SWAPKIN_DIR/providers/copilot/other"
jq -n '{user:"octo-work"}' > "$SWAPKIN_DIR/providers/copilot/work/copilot.json"
jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/providers/copilot/work/meta.json"
jq -n '{user:"octo-other"}' > "$SWAPKIN_DIR/providers/copilot/other/copilot.json"
jq -n '{colour:"#d97757"}' > "$SWAPKIN_DIR/providers/copilot/other/meta.json"
# The stored pointer says 'other', but gh (the fixture) says octo-work is active.
echo other > "$SWAPKIN_DIR/providers/copilot/active"

out=$(sk "$SWAPKIN" -p copilot status)
assert_contains "status reads gh's real active login, not the stale stored pointer" "$out" "work"

out2=$(sk "$SWAPKIN" -p copilot use work)
switch_log=$(cat "$GH_SWITCH_LOG")
assert_contains "use still calls gh auth switch even though gh already agrees" "$switch_log" "octo-work"

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

# ================================================================== summary ==
echo
echo "19. no captured test output contains a fixture token string"
if grep -qF "$LIVE_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$STALE_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$PERSONAL_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$GH_SECRET_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null \
   || grep -qF "$SENTINEL_TOKEN" "$ALL_OUTPUT_LOG" 2>/dev/null; then
  bad "no captured test output contains any fixture token string"
else
  ok "no captured test output contains any fixture token string"
fi

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
