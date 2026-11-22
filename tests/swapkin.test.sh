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
# Default secret-tool finds nothing, so the real keyring never decides a test.
mk_stub secret-tool "exit 1"
# No test reaches the real profile endpoint: default curl fails (= offline).
mk_stub curl "exit 7"

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

# ============================ claude profile keeps its own oauthAccount (#5) ==
echo "claude save/use never mix in another account's oauthAccount"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" CLAUDE_CONFIG_DIR="$S/home/.claude" \
       XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" \
       PATH="$STUBS:$PATH" SWAPKIN_DEMO=0
unset SWAPKIN_PROVIDER
mkdir -p "$CLAUDE_CONFIG_DIR" "$SWAPKIN_DIR/a" "$SWAPKIN_DIR/b"
UA=aaaaaaaa-0000-0000-0000-000000000001; UB=bbbbbbbb-0000-0000-0000-000000000002
TA=$(printf 'a%.0s' {1..45}); TB=$(printf 'b%.0s' {1..45})
# stub profile endpoint: the access token says who it is
mk_stub curl 'for a; do :; done; case "$*" in *"Bearer acc-a"*) echo "{\"account\":{\"uuid\":\"'$UA'\"}}";; *"Bearer acc-b"*) echo "{\"account\":{\"uuid\":\"'$UB'\"}}";; *) exit 7;; esac'
jq -n --arg t "$TB" '{claudeAiOauth:{refreshToken:$t, accessToken:"acc-b", subscriptionType:"max"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
# an old session rewrote the shared file with account A
jq -n --arg u "$UA" '{oauthAccount:{accountUuid:$u,planDisplayName:"A-plan"}}' > "$CLAUDE_CONFIG_DIR/.claude.json"
jq -n --arg u "$UB" '{oauthAccount:{accountUuid:$u,planDisplayName:"B-plan"}}' > "$SWAPKIN_DIR/b/account.json"
jq -n --arg t "$TA" '{refreshToken:$t, accessToken:"acc-a", subscriptionType:"max"}' > "$SWAPKIN_DIR/a/oauth.json"
jq -n --arg u "$UA" '{oauthAccount:{accountUuid:$u,planDisplayName:"A-plan"}}' > "$SWAPKIN_DIR/a/account.json"
echo b > "$SWAPKIN_DIR/active"
sk "$SWAPKIN" use a >/dev/null
assert_eq "save: B's profile kept B's oauthAccount, not the live A one" "$UB" "$(jq -r .oauthAccount.accountUuid "$SWAPKIN_DIR/b/account.json")"
assert_contains "mismatch is logged" "$(cat "$XDG_STATE_HOME/swapkin/autoswitch.log" 2>/dev/null)" "account mismatch"
assert_eq "use: live oauthAccount is A's after switching to A" "$UA" "$(jq -r .oauthAccount.accountUuid "$CLAUDE_CONFIG_DIR/.claude.json")"
# a profile that already holds the wrong account is not merged on use
jq -n --arg u "$UB" '{oauthAccount:{accountUuid:$u,planDisplayName:"B-plan"}}' > "$SWAPKIN_DIR/a/account.json"
jq -n '{theme:"dark"}' > "$CLAUDE_CONFIG_DIR/.claude.json"
sk "$SWAPKIN" use b >/dev/null; sk "$SWAPKIN" use a >/dev/null
assert_eq "use: another account's oauthAccount is not merged" "" "$(jq -r '.oauthAccount.accountUuid // empty' "$CLAUDE_CONFIG_DIR/.claude.json")"
# offline: keep the previous saved one when live disagrees
mk_stub curl "exit 7"
jq -n --arg t "$TB" '{claudeAiOauth:{refreshToken:$t, accessToken:"acc-b"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
jq -n --arg u "$UA" '{oauthAccount:{accountUuid:$u}}' > "$CLAUDE_CONFIG_DIR/.claude.json"
echo b > "$SWAPKIN_DIR/active"
sk "$SWAPKIN" use a >/dev/null
assert_eq "offline: saved oauthAccount kept when live disagrees" "$UB" "$(jq -r .oauthAccount.accountUuid "$SWAPKIN_DIR/b/account.json")"
mk_stub curl "exit 7"

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
{"providers":[{"id":"unsafe","name":"Unsafe","command":"unsafe","mode":"cold","homeEnv":"DUMMY_HOME","defaultHome":"~/.dummy"}]}
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

# ============================== 9b. agy (Antigravity) built-in, never mode ==
echo "9b. agy is a built-in never-mode provider, listed only with its own login"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" SWAPKIN_DEMO=0
unset SWAPKIN_DEMO_FILE
mkdir -p "$HOME/.gemini/antigravity-cli" "$S/agybin"
echo fake > "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
printf '#!/bin/sh\nexit 0\n' > "$S/agybin/agy"; chmod +x "$S/agybin/agy"
# stub secret-tool: finds an item only while $S/keyring exists; prints a fake token
printf '#!/bin/sh\n[ -f "%s/keyring" ] && { echo FAKE-TOKEN; exit 0; }\nexit 1\n' "$S" > "$S/agybin/secret-tool"
chmod +x "$S/agybin/secret-tool"
out=$(PATH="$S/agybin:$STUBS:$PATH" "$SWAPKIN" providers --json 2>/dev/null)
got=$(jq -c '.providers[]|select(.id=="agy")|{id,mode,installed}' <<<"$out")
assert_eq "agy listed as never + installed with a fake agy on PATH" '{"id":"agy","mode":"never","installed":true}' "$got"
out=$(PATH="$STUBS:/usr/bin:/bin" "$SWAPKIN" providers --json 2>/dev/null)
assert_eq "agy logged in (file) but no binary: installed false" "false" "$(jq -r '.providers[]|select(.id=="agy")|.installed' <<<"$out")"
rm "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
out=$(PATH="$S/agybin:$STUBS:$PATH" "$SWAPKIN" providers --json 2>/dev/null)
assert_eq "agy absent when installed but not logged in" "" "$(jq -c '.providers[]|select(.id=="agy")' <<<"$out")"
touch "$S/keyring"
out=$(PATH="$S/agybin:$STUBS:$PATH" "$SWAPKIN" providers --json 2>/dev/null)
assert_eq "agy listed when only the keyring item exists" '{"id":"agy","mode":"never","installed":true}' "$(jq -c '.providers[]|select(.id=="agy")|{id,mode,installed}' <<<"$out")"
assert_not_contains "keyring token never reaches the output" "$out" "FAKE-TOKEN"
out=$(PATH="$S/agybin:$STUBS:$PATH" "$SWAPKIN" -p agy add x 2>&1)
assert_contains "add is not supported for agy" "$out" "add is not supported for agy"
assert_contains "30-day Codex window is labelled Monthly" "$(cat "$ROOT/bin/providers/codex.sh")" 'win == 43200 ]]; then label="Monthly (30-day)"'

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

# ============== 20. custom defaultHome must resolve under $HOME, symlinks followed ==
echo "20. a custom defaultHome that resolves outside \$HOME is refused; one symlinked inside \$HOME is fine"
# Custom providers are cold-only, and a cold provider never writes to
# defaultHome: swapkin resolves it once, stores the string in custom.json and
# hands it to the tool through homeEnv. There is no check-then-write on that
# path left to race, so this is not a TOCTOU test. What it does pin is the
# weaker, real property: the check follows symlinks (readlink -f -m), so an
# ancestor pointing outside $HOME is refused rather than stored, and a
# dotfile directory symlinked to somewhere else inside $HOME is accepted.
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
mkdir -p "$XDG_CONFIG_HOME/swapkin"
cat > "$XDG_CONFIG_HOME/swapkin/providers.json" <<JSON
{"providers":[{"id":"acme","name":"Acme CLI","command":"acme","mode":"cold","homeEnv":"ACME_HOME","defaultHome":"~/.acme/home"}]}
JSON
chmod 600 "$XDG_CONFIG_HOME/swapkin/providers.json"

# ~/.acme (an ancestor of defaultHome, not the leaf) points outside $HOME.
OUTSIDE="$S/outside-home"
mkdir -p "$OUTSIDE/home"
ln -s "$OUTSIDE" "$HOME/.acme"
out=$("$SWAPKIN" -p acme add mallory 2>&1); rc=$?
echo "$out" >> "$ALL_OUTPUT_LOG"
assert_true [ "$rc" -ne 0 ]
assert_contains "a defaultHome resolving outside \$HOME is refused" "$out" "must resolve under \$HOME"
assert_true [ ! -e "$SWAPKIN_DIR/providers/acme/mallory" ]

# The same ancestor symlinked to a directory inside $HOME is a normal
# dotfiles setup, and is accepted with the resolved path stored.
rm -f "$HOME/.acme"
mkdir -p "$HOME/dotfiles/acme/home"
ln -s "$HOME/dotfiles/acme" "$HOME/.acme"
out=$(sk "$SWAPKIN" -p acme add work)
assert_contains "a defaultHome symlinked inside \$HOME is accepted" "$out" "Saved the current Acme CLI login as 'work'."
stored=$(jq -r '.home' "$SWAPKIN_DIR/providers/acme/work/custom.json" 2>/dev/null)
assert_eq "the stored home is the resolved path" "$(readlink -f "$HOME")/dotfiles/acme/home" "$stored"

# ====================== 21. custom hot mode / loginFiles are refused, nothing written ==
echo "21. a custom provider asking for hot mode or loginFiles is refused before anything is written"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH"
# Installed stubs, so that without the refusal both would be listed.
mk_stub acmehot 'exit 0'
mk_stub acmelegacy 'exit 0'
mkdir -p "$XDG_CONFIG_HOME/swapkin" "$HOME/.acmehot"
cat > "$XDG_CONFIG_HOME/swapkin/providers.json" <<JSON
{"providers":[
 {"id":"acmehot","name":"Acme Hot","command":"acmehot","mode":"hot","loginFiles":["~/.acmehot/session.json"]},
 {"id":"acmelegacy","name":"Acme Legacy","command":"acmelegacy","mode":"cold","homeEnv":"ACME_LEGACY_HOME","defaultHome":"~/.acmelegacy","loginFiles":["~/.acmelegacy/session.json"]}
]}
JSON
chmod 600 "$XDG_CONFIG_HOME/swapkin/providers.json"
echo '{"session":"hot-live"}' > "$HOME/.acmehot/session.json"

out=$("$SWAPKIN" providers --json 2>"$S/stderr.log")
err=$(cat "$S/stderr.log")
echo "$out" >> "$ALL_OUTPUT_LOG"; echo "$err" >> "$ALL_OUTPUT_LOG"
assert_contains "providers --json warns about the hot entry" "$err" "swapkin: ignoring custom provider 'acmehot' (custom providers are cold-only"
assert_contains "providers --json warns about the loginFiles entry" "$err" "swapkin: ignoring custom provider 'acmelegacy' (custom providers are cold-only"
assert_not_contains "the hot entry is not listed" "$out" '"id":"acmehot"'
assert_not_contains "the loginFiles entry is not listed" "$out" '"id":"acmelegacy"'

for id in acmehot acmelegacy; do
  out=$("$SWAPKIN" -p "$id" add work 2>&1); rc=$?
  echo "$out" >> "$ALL_OUTPUT_LOG"
  assert_true [ "$rc" -ne 0 ]
  assert_contains "$id add is refused with the cold-only message" "$out" "custom providers are cold-only"
  assert_true [ ! -e "$SWAPKIN_DIR/providers/$id" ]
done
assert_eq "the live login file is untouched" '{"session":"hot-live"}' "$(cat "$HOME/.acmehot/session.json")"

# ========================================= 22. sync scan caps a hostile folder ==
echo "22. the optional sync scan skips oversized files and caps file count and total bytes"
# The script is extracted from Main.qml as text, never hand-copied, so this
# test tracks the real source and goes red on drift.
SYNC_SCRIPT=$(node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
const m = src.match(/var script = "((?:[^"\\]|\\.)*)"/);
if (!m) { process.exit(1); }
process.stdout.write(JSON.parse("\"" + m[1] + "\""));
' "$ROOT/Main.qml")
if [[ -z "$SYNC_SCRIPT" ]]; then
  bad "extracted the sync scan script from Main.qml's startSyncScan()"
else
  ok "extracted the sync scan script from Main.qml's startSyncScan()"

  SYNC_DIR=$(mktemp -d)
  # Two valid, real-sized snapshots.
  echo '{"providers":{"acme":{"days":{"2026-09-27":{"model-a":1}}}}}' > "$SYNC_DIR/work.json"
  echo '{"providers":{"orbit":{"days":{"2026-09-27":{"model-b":2}}}}}' > "$SYNC_DIR/personal.json"
  # One hostile file, bigger than the per-file cap (256 KiB).
  python3 -c "print('{\"providers\":{\"evil\":\"' + 'A' * 400000 + '\"}}')" > "$SYNC_DIR/huge.json"
  # More files than the file-count cap (32): 40 small, same-content files.
  for i in $(seq 1 40); do
    echo "{\"providers\":{\"peer$i\":{\"days\":{}}}}" > "$SYNC_DIR/peer$i.json"
  done
  touch -d "2020-01-01" "$SYNC_DIR"/peer*.json

  sync_out=$(bash -c "$SYNC_SCRIPT" "$SYNC_DIR")

  block_count=$(grep -c "^=== EOM ===$" <<<"$sync_out")
  total_bytes=$(printf '%s' "$sync_out" | wc -c)

  assert_not_contains "the oversized file's content is not in stdout" "$sync_out" "AAAAAAAAAA"
  assert_contains "a valid file still parses (path marker present)" "$sync_out" "===$SYNC_DIR/work.json==="
  assert_contains "a valid file's body survived" "$sync_out" '"model-a":1'
  assert_true [ "$block_count" -le 32 ]
  assert_true [ "$total_bytes" -le 2097152 ]

  # Same-content valid blocks JSON.parse cleanly with the app's own split logic.
  parse_ok=$(node -e '
    const fs = require("fs");
    const text = fs.readFileSync(process.argv[1], "utf8");
    const lines = text.split("\n");
    let path = "", buf = [], parsed = 0;
    function flush() {
      if (path === "") return;
      try {
        const j = JSON.parse(buf.join("\n").trim());
        if (j && j.providers) parsed++;
      } catch (e) {}
      path = ""; buf = [];
    }
    for (const line of lines) {
      const m = line.match(/^===(.*)===$/);
      if (m && m[1] !== " EOM ") { flush(); path = m[1]; continue; }
      if (line === "=== EOM ===") { flush(); continue; }
      if (path !== "") buf.push(line);
    }
    flush();
    process.stdout.write(String(parsed));
  ' <(printf '%s' "$sync_out"))
  assert_true [ "$parse_ok" -ge 2 ]

  rm -rf "$SYNC_DIR"
fi

# ============================================== 21. auto-switch near the limit ==
# Fake accounts under a temp SWAPKIN_DIR with hand-written usage.json files.
# `swapkin check` is the real entry point; no omarchy-agent-usage-claude stub is
# on PATH, so the figures are exactly what each scenario seeds.
mk_stub notify-send '[[ -n "${NOTIFY_LOG:-}" ]] && echo "$*" >> "$NOTIFY_LOG"; true'

lim() { # label fraction-used when
  jq -nc --arg l "$1" --argjson p "$2" --arg r "$(date -u -d "$3" +%Y-%m-%dT%H:%M:%S+00:00)" \
    '{label:$l,percent:$p,resetsAt:$r}'
}
SESSION="Session (5-hour)"; WEEKLY="Weekly (7-day)"; FABLE="Fable Weekly"
auto_account() { # name token-char
  mkdir -p "$SWAPKIN_DIR/$1"
  echo '{"refreshToken":"'"$(printf "$2%.0s" {1..40})"'","subscriptionType":"max"}' > "$SWAPKIN_DIR/$1/oauth.json"
  echo '{}' > "$SWAPKIN_DIR/$1/account.json"
  jq -n '{colour:"#7fa7d9"}' > "$SWAPKIN_DIR/$1/meta.json"
}
auto_usage() { # name limit-json...
  local name="$1"; shift
  printf '%s\n' "$@" | jq -sc '{limits:.}' > "$SWAPKIN_DIR/$name/usage.json"
}
auto_world() { # config-json ; builds personal (active) + work
  S=$(sandbox)
  export HOME="$S/home" SWAPKIN_DIR="$S/data" CLAUDE_CONFIG_DIR="$S/home/.claude" \
         XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" \
         PATH="$STUBS:$PATH" SWAPKIN_DEMO=0 NOTIFY_LOG="$S/notify.log"
  unset SWAPKIN_AUTOSWITCH SWAPKIN_AUTOSWITCHLEFTPCT SWAPKIN_AUTOSWITCHRETURN
  mkdir -p "$CLAUDE_CONFIG_DIR"
  jq -n '{claudeAiOauth:{refreshToken:"'"$(printf 'p%.0s' {1..40})"'", subscriptionType:"max"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
  jq -n '{theme:"dark"}' > "$CLAUDE_CONFIG_DIR/.claude.json"
  auto_account personal p
  auto_account work w
  echo personal > "$SWAPKIN_DIR/active"
  echo "$1" > "$SWAPKIN_DIR/config.json"
  : > "$NOTIFY_LOG"
}
healthy() { auto_usage "$1" "$(lim "$SESSION" 0.20 '+3 hours')" "$(lim "$WEEKLY" 0.30 '+3 days')" "$(lim "$FABLE" 0.10 '+3 days')"; }
active_is() { cat "$SWAPKIN_DIR/active"; }
AUTOLOG() { echo "$XDG_STATE_HOME/swapkin/autoswitch.log"; }
# Pretend every window the watchdog remembered has now reset.
windows_reset() {
  jq '(.. | numbers) |= (if . > 1000000000 then 1 else . end)' "$SWAPKIN_DIR/watch.json" > "$SWAPKIN_DIR/watch.json.new" \
    && mv "$SWAPKIN_DIR/watch.json.new" "$SWAPKIN_DIR/watch.json"
}
LOW_SESSION() { auto_usage "$1" "$(lim "$SESSION" "${2:-0.97}" '+2 hours')" "$(lim "$WEEKLY" 0.30 '+3 days')"; }

echo "21a. each limit triggers a switch; the roomy account takes over"
for which in session weekly fable; do
  auto_world '{"autoSwitch":true}'
  healthy work
  case $which in
    session) LOW_SESSION personal 0.96 ;;
    weekly)  auto_usage personal "$(lim "$SESSION" 0.20 '+2 hours')" "$(lim "$WEEKLY" 0.97 '+3 days')" ;;
    fable)   auto_usage personal "$(lim "$SESSION" 0.20 '+2 hours')" "$(lim "$WEEKLY" 0.30 '+3 days')" "$(lim "$FABLE" 0.98 '+3 days')" ;;
  esac
  sk "$SWAPKIN" check >/dev/null
  assert_eq "$which limit nearly spent: switches to work" work "$(active_is)"
  assert_contains "$which: the notification says where it went" "$(cat "$NOTIFY_LOG")" "Switched to work"
  assert_contains "$which: the log records the switch" "$(cat "$(AUTOLOG)")" "switched personal -> work"
done

echo "21b. the threshold is inclusive, configurable, and off means off"
auto_world '{"autoSwitch":true}'; healthy work; LOW_SESSION personal 0.95
sk "$SWAPKIN" check >/dev/null
assert_eq "exactly 5% left switches (default threshold)" work "$(active_is)"
auto_world '{"autoSwitch":true}'; healthy work; LOW_SESSION personal 0.94
sk "$SWAPKIN" check >/dev/null
assert_eq "6% left stays put" personal "$(active_is)"
auto_world '{"autoSwitch":true,"autoSwitchLeftPct":10}'; healthy work; LOW_SESSION personal 0.92
sk "$SWAPKIN" check >/dev/null
assert_eq "autoSwitchLeftPct 10 switches at 8% left" work "$(active_is)"
auto_world '{"autoSwitch":false}'; healthy work; LOW_SESSION personal 0.99
sk "$SWAPKIN" check >/dev/null
assert_eq "autoSwitch off never switches" personal "$(active_is)"
auto_world '{"autoSwitch":false}'; healthy work; LOW_SESSION personal 0.99
SWAPKIN_AUTOSWITCH=true sk "$SWAPKIN" check >/dev/null
assert_eq "the widget setting (env) beats config.json" work "$(active_is)"

echo "21b2. the log says why nothing switched, and an env-only setting switches"
auto_world '{}'; healthy work; LOW_SESSION personal 0.96
sk "$SWAPKIN" check >/dev/null
assert_eq "no config, no env: stays put" personal "$(active_is)"
assert_contains "off is logged, not silent" "$(cat "$(AUTOLOG)")" "auto-switch is off"
auto_world '{}'; healthy work; LOW_SESSION personal 0.50
SWAPKIN_AUTOSWITCH=true SWAPKIN_AUTOSWITCHLEFTPCT=1 sk "$SWAPKIN" check >/dev/null
assert_eq "above the threshold: stays put" personal "$(active_is)"
assert_contains "threshold not reached is logged" "$(cat "$(AUTOLOG)")" "above the 1% threshold"
auto_world '{}'; healthy work; LOW_SESSION personal 0.50
SWAPKIN_AUTOSWITCH=true SWAPKIN_AUTOSWITCHLEFTPCT=55 sk "$SWAPKIN" check >/dev/null
assert_eq "env only (no config.json): left 50% <= 55% switches" work "$(active_is)"
assert_contains "the switch is logged" "$(cat "$(AUTOLOG)")" "switched personal -> work"

echo "21c. no target: stay, warn once"
auto_world '{"autoSwitch":true}'
LOW_SESSION personal 0.97; LOW_SESSION work 0.97
sk "$SWAPKIN" check >/dev/null; sk "$SWAPKIN" check >/dev/null
assert_eq "both low: no switch" personal "$(active_is)"
assert_eq "the warning goes out once" 1 "$(grep -c 'No other account has room' "$NOTIFY_LOG")"

echo "21d. a target that is low on any one limit is never chosen"
auto_world '{"autoSwitch":true}'
LOW_SESSION personal 0.99
auto_usage work "$(lim "$SESSION" 0.10 '+2 hours')" "$(lim "$WEEKLY" 0.10 '+3 days')" "$(lim "$FABLE" 0.96 '+3 days')"
sk "$SWAPKIN" check >/dev/null
assert_eq "work is roomy on weekly but spent on Fable: stay" personal "$(active_is)"
assert_contains "and the owner is told" "$(cat "$NOTIFY_LOG")" "No other account has room"

echo "21e. no ping-pong: one switch per window, the source is not a target until it resets"
auto_world '{"autoSwitch":true}'; healthy work; LOW_SESSION personal
sk "$SWAPKIN" check >/dev/null
assert_eq "first switch lands" work "$(active_is)"
# work now runs low and personal looks healthy again, but its window has not reset
healthy personal; LOW_SESSION work
sk "$SWAPKIN" check >/dev/null
assert_eq "the account we left is not a target before its reset" work "$(active_is)"
# the owner goes back by hand while the old window is still open
sk "$SWAPKIN" use personal >/dev/null
LOW_SESSION personal; healthy work
sk "$SWAPKIN" check >/dev/null
assert_eq "the same window never triggers a second switch" personal "$(active_is)"
assert_eq "one 'Switched to' notification in all" 1 "$(grep -c 'Switched to' "$NOTIFY_LOG")"
# the window resets: the stored block expires and the account can be used again
windows_reset
auto_usage personal "$(lim "$SESSION" 0.97 '+9 hours')" "$(lim "$WEEKLY" 0.30 '+3 days')"
sk "$SWAPKIN" check >/dev/null
assert_eq "a new window can switch again" work "$(active_is)"

echo "21f. a session-limit switch does not return by itself unless autoSwitchReturn is on"
for ret in false true; do
  auto_world '{"autoSwitch":true,"autoSwitchReturn":'$ret'}'
  healthy work; LOW_SESSION personal
  sk "$SWAPKIN" check >/dev/null
  # personal's session resets; work has been in use and is now the fuller one
  windows_reset
  healthy personal
  auto_usage work "$(lim "$SESSION" 0.60 '+2 hours')" "$(lim "$WEEKLY" 0.70 '+3 days')"
  sk "$SWAPKIN" check >/dev/null
  if [[ $ret == true ]]; then
    assert_eq "return on: back to the original once it recovered and is roomier" personal "$(active_is)"
    sk "$SWAPKIN" use work >/dev/null
    sk "$SWAPKIN" check >/dev/null
    assert_eq "return happens at most once per switch" work "$(active_is)"
  else
    assert_eq "return off: stays on the account it moved to" work "$(active_is)"
  fi
done
auto_world '{"autoSwitch":true,"autoSwitchReturn":true}'
healthy work; LOW_SESSION personal
sk "$SWAPKIN" check >/dev/null
windows_reset
auto_usage personal "$(lim "$SESSION" 0.50 '+2 hours')" "$(lim "$WEEKLY" 0.97 '+3 days')"
sk "$SWAPKIN" check >/dev/null
assert_eq "return on: not while the original is still low on another limit" work "$(active_is)"

echo "21g. stale, unreadable or missing figures do nothing"
auto_world '{"autoSwitch":true}'; healthy work; LOW_SESSION personal 0.99
touch -d '3 hours ago' "$SWAPKIN_DIR/personal/usage.json"
sk "$SWAPKIN" check >/dev/null
assert_eq "stale figures for the active account: no switch" personal "$(active_is)"
assert_contains "the log says why" "$(cat "$(AUTOLOG)")" "stale"
auto_world '{"autoSwitch":true}'; healthy work
echo 'not json' > "$SWAPKIN_DIR/personal/usage.json"
sk "$SWAPKIN" check >/dev/null
assert_eq "unreadable figures: no switch" personal "$(active_is)"
auto_world '{"autoSwitch":true}'; healthy work; LOW_SESSION personal 0.99
touch -d '3 hours ago' "$SWAPKIN_DIR/work/usage.json"
sk "$SWAPKIN" check >/dev/null
assert_eq "stale figures for the target: no switch" personal "$(active_is)"
auto_world '{"autoSwitch":true}'; healthy work; LOW_SESSION personal 0.99
echo '{"refreshToken":"short","subscriptionType":"max"}' > "$SWAPKIN_DIR/work/oauth.json"
sk "$SWAPKIN" check >/dev/null
assert_eq "a target without a real login: no switch" personal "$(active_is)"

echo "21h. the decision log keeps the last 200 lines"
auto_world '{"autoSwitch":true}'
mkdir -p "$(dirname "$(AUTOLOG)")"
for i in $(seq 1 300); do echo "old line $i" >> "$(AUTOLOG)"; done
healthy work; LOW_SESSION personal 0.99
sk "$SWAPKIN" check >/dev/null
assert_eq "log trimmed to 200 lines" 200 "$(wc -l < "$(AUTOLOG)")"
assert_contains "newest line is the switch" "$(tail -1 "$(AUTOLOG)")" "switched personal -> work"

# ============= 23. visibility: saved account or the CLI's own login, not gh ==
echo "23. gh alone does not list Copilot; a Codex CLI login with zero accounts does"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" XDG_CONFIG_HOME="$S/config" \
       XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" PATH="$STUBS:$PATH" SWAPKIN_DEMO=0
unset SWAPKIN_DEMO_FILE SWAPKIN_PROVIDER
# gh is installed (on PATH), but no account has been saved in swapkin yet.
mk_stub gh "case \"\$1 \$2\" in 'auth status') cat '$FIXTURES/gh-auth-status.json' ;; esac"

out=$(sk "$SWAPKIN" providers --json)
assert_not_contains "installed copilot with zero accounts is not listed" "$out" '"id":"copilot"'
assert_eq "no provider is listed with no account and no CLI login" 0 "$(jq '.providers | length' <<<"$out")"

# Codex has zero saved accounts too, but is logged in at ~/.codex/auth.json.
mkdir -p "$HOME/.codex"
echo '{"tokens":{"id_token":"fixture"}}' > "$HOME/.codex/auth.json"
out=$(sk "$SWAPKIN" providers --json)
assert_contains "logged-in codex with zero saved accounts is listed" "$out" '"id":"codex"'
assert_eq "codex has no saved accounts in the listing" 0 \
  "$(jq '.providers[] | select(.id == "codex") | .accounts | length' <<<"$out")"
assert_not_contains "a gh login still does not list copilot" "$out" '"id":"copilot"'

# The first account still comes from `swapkin -p copilot add` and makes it appear.
out=$(sk "$SWAPKIN" -p copilot add work)
assert_contains "copilot add still works with no saved accounts" "$out" "Saved 'work'"
out=$(sk "$SWAPKIN" providers --json)
assert_contains "copilot is listed once it has a saved account" "$out" '"id":"copilot"'
assert_eq "the saved account is in the listing" 1 "$(jq '[.providers[] | select(.id == "copilot") | .accounts[]] | length' <<<"$out")"

# ============================ 24. Claude plan label comes from the API =======
echo "24. Claude's label is the API's plan name, not a mapped rate-limit tier"
S=$(sandbox)
export HOME="$S/home" SWAPKIN_DIR="$S/data" CLAUDE_CONFIG_DIR="$S/home/.claude" \
       XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" XDG_CACHE_HOME="$S/cache" \
       PATH="$STUBS:$PATH" SWAPKIN_DEMO=0
unset SWAPKIN_DEMO_FILE

# The limits tool reports the tier-derived name; the API profile says Ultra.
mk_stub omarchy-agent-usage-claude 'echo "{\"limits\":[{\"label\":\"Weekly\",\"percent\":0.2}],\"tierLabel\":\"Max 20x\",\"updatedAt\":\"2026-11-21T12:00:00Z\"}"'

mkdir -p "$CLAUDE_CONFIG_DIR" "$SWAPKIN_DIR/work" "$SWAPKIN_DIR/personal" "$SWAPKIN_DIR/raw"
jq -n --arg t "$(printf 'x%.0s' {1..40})" '{claudeAiOauth:{refreshToken:$t, subscriptionType:"max"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
jq -c . "$FIXTURES/claude-account.json" > "$CLAUDE_CONFIG_DIR/.claude.json"

for acct in work personal raw; do
  case "$acct" in
    work) letter=x; plan=max ;;
    personal) letter=y; plan=pro ;;
    raw) letter=z; plan=team ;;
  esac
  jq -n --arg t "$(printf "$letter%.0s" {1..40})" --arg p "$plan" \
    '{refreshToken:$t, subscriptionType:$p}' > "$SWAPKIN_DIR/$acct/oauth.json"
  jq -n --arg c '#7fa7d9' '{colour:$c}' > "$SWAPKIN_DIR/$acct/meta.json"
done
jq '.oauthAccount.planDisplayName = "Claude Pro"' "$FIXTURES/claude-account.json" > "$SWAPKIN_DIR/personal/account.json"
echo '{}' > "$SWAPKIN_DIR/raw/account.json"
echo work > "$SWAPKIN_DIR/active"

sk "$SWAPKIN" -p claude usage >/dev/null
assert_eq "active account takes the API profile's plan name" "Ultra" "$(jq -r .tierLabel "$SWAPKIN_DIR/work/usage.json")"
assert_eq "idle account takes its own API plan name verbatim" "Claude Pro" "$(jq -r .tierLabel "$SWAPKIN_DIR/personal/usage.json")"
assert_eq "without an API name the raw credential value is kept" "team" "$(jq -r .tierLabel "$SWAPKIN_DIR/raw/usage.json")"

out=$(sk "$SWAPKIN" providers --json)
assert_eq "panel tierLabel for the active account" "Ultra" "$(jq -r '.providers[] | select(.id=="claude") | .accounts[] | select(.name=="work") | .tierLabel' <<<"$out")"
assert_eq "plan field for an idle account" "Claude Pro" "$(jq -r '.providers[] | select(.id=="claude") | .accounts[] | select(.name=="personal") | .plan' <<<"$out")"
assert_eq "plan field falls back to the raw value" "team" "$(jq -r '.providers[] | select(.id=="claude") | .accounts[] | select(.name=="raw") | .plan' <<<"$out")"
assert_not_contains "no tier-derived plan name reaches the panel" "$out" "Max 20x"
assert_eq "active account's plan field is the API name the panel header reads" "Ultra" "$(jq -r '.providers[] | select(.id=="claude") | .accounts[] | select(.active) | .plan' <<<"$out")"
assert_contains "Main.qml prefers the active account's plan over the record's tierLabel" "$(grep 'tierLabel: activePlanName' "$ROOT/Main.qml")" "|| String(record.tierLabel"
rm -f "$STUBS/omarchy-agent-usage-claude"

# Right after a switch ~/.claude.json still holds the previous account's profile:
# the account's own saved account.json wins, and the live file counts only for the
# same login.
jq '.oauthAccount.planDisplayName = "Claude Pro" | .oauthAccount.accountUuid = "uuid-personal"' "$FIXTURES/claude-account.json" > "$SWAPKIN_DIR/personal/account.json"
echo personal > "$SWAPKIN_DIR/active"
out=$(sk "$SWAPKIN" providers --json)
assert_eq "stale ~/.claude.json plan is not shown for the new active account" "Claude Pro" "$(jq -r '.providers[] | select(.id=="claude") | .accounts[] | select(.active) | .plan' <<<"$out")"
echo '{"oauthAccount":{"planDisplayName":"Claude Pro","accountUuid":"uuid-personal"}}' > "$SWAPKIN_DIR/personal/account.json"
assert_eq "active account reads its own account.json first" "Claude Pro" "$(sk "$SWAPKIN" providers --json | jq -r '.providers[] | select(.id=="claude") | .accounts[] | select(.name=="personal") | .plan')"
echo '{"oauthAccount":{"accountUuid":"uuid-other"}}' > "$SWAPKIN_DIR/personal/account.json"
assert_eq "live profile of another login is not trusted; credential value used" "pro" "$(sk "$SWAPKIN" providers --json | jq -r '.providers[] | select(.id=="claude") | .accounts[] | select(.name=="personal") | .plan')"
echo work > "$SWAPKIN_DIR/active"

# One service run = one log line; a repeat bumps a count, a changed setting logs anew.
LOGF="$XDG_STATE_HOME/swapkin/autoswitch.log"; rm -f "$LOGF"
sk env SWAPKIN_AUTOSWITCH=false "$SWAPKIN" check >/dev/null
sk env SWAPKIN_AUTOSWITCH=false "$SWAPKIN" check >/dev/null
assert_contains "repeated runs collapse into a counted line" "$(cat "$LOGF")" "(x2)"
sk env SWAPKIN_AUTOSWITCH=false SWAPKIN_AUTOSWITCHLEFTPCT=9 "$SWAPKIN" check >/dev/null
assert_contains "a changed setting leaves its own line" "$(cat "$LOGF")" "leftPct=9"
assert_contains "the first setting line is still there" "$(cat "$LOGF")" "leftPct=5"

# Service.qml re-reads shell.json before each pass and never gates the timer on that read.
assert_contains "Service.qml reloads shell.json per pass" "$(cat "$ROOT/Service.qml")" "shellFile.reload()"
assert_not_contains "Service.qml timer not gated on fileSettled" "$(cat "$ROOT/Service.qml")" "fileSettled"

# ============================== 25. label: a display name, and signedIn ======
echo "25. label shows an account under another name; providers --json says signedIn"
SB=$(sandbox)
export HOME="$SB/home" SWAPKIN_DIR="$SB/data" XDG_DATA_HOME="$SB/data-xdg" XDG_CONFIG_HOME="$SB/config"
mkdir -p "$SWAPKIN_DIR/work" "$HOME/.claude"
echo work > "$SWAPKIN_DIR/active"
echo '{}' > "$SWAPKIN_DIR/work/oauth.json"
echo '{}' > "$HOME/.claude/.credentials.json"
sk "$SWAPKIN" -p claude label work "Day job" >/dev/null
assert_eq "label is stored beside the account, the id stays" "Day job" "$(cat "$SWAPKIN_DIR/work/label")"
out=$(sk "$SWAPKIN" providers --json)
assert_eq "providers --json carries the label" "Day job" "$(jq -r '.providers[] | select(.id=="claude") | .accounts[0].label' <<<"$out")"
assert_eq "the account name is untouched" "work" "$(jq -r '.providers[] | select(.id=="claude") | .accounts[0].name' <<<"$out")"
assert_eq "a signed-in CLI reports signedIn" "true" "$(jq -r '.providers[] | select(.id=="claude") | .signedIn' <<<"$out")"
sk "$SWAPKIN" -p claude label work "" >/dev/null
assert_true test ! -e "$SWAPKIN_DIR/work/label"
res=$(sk "$SWAPKIN" -p claude label nobody x || true)
assert_contains "label on an unknown account fails" "$res" "no account named"

# ================================== 26. rate-limited probe is remembered ======
echo "26. a rate limited usage probe is reported as rateLimited, not as a sign-out"
SB=$(sandbox)
export HOME="$SB/home" SWAPKIN_DIR="$SB/data" XDG_DATA_HOME="$SB/data-xdg" XDG_CONFIG_HOME="$SB/config"
mkdir -p "$SWAPKIN_DIR/work" "$HOME/.claude"
echo work > "$SWAPKIN_DIR/active"
echo '{"accessToken":"x","refreshToken":"y","expiresAt":9999999999999}' > "$SWAPKIN_DIR/work/oauth.json"
echo '{}' > "$HOME/.claude/.credentials.json"
mk_stub omarchy-agent-usage-claude 'echo "{\"limits\":[{\"label\":\"Weekly\",\"percent\":0.2}],\"authHelpText\":\"Anthropic usage endpoint is rate limiting checks right now.\"}"'
PATH="$STUBS:$PATH" sk "$SWAPKIN" -p claude usage >/dev/null
assert_true test -s "$SWAPKIN_DIR/work/ratelimit"
out=$(sk "$SWAPKIN" providers --json)
assert_eq "providers --json says rateLimited" "true" "$(jq -r '.providers[] | select(.id=="claude") | .rateLimited' <<<"$out")"
assert_true test ! -e "$SWAPKIN_DIR/work/usage.json"   # estimates never replace the last real figures
mk_stub omarchy-agent-usage-claude 'echo "{\"limits\":[{\"label\":\"Weekly\",\"percent\":0.2}],\"authHelpText\":\"Anthropic usage endpoint is rate limiting checks right now (retry after 1200s).\"}"'
PATH="$STUBS:$PATH" sk "$SWAPKIN" -p claude usage >/dev/null
assert_true test -s "$SWAPKIN_DIR/work/ratelimit.until"
out=$(sk "$SWAPKIN" providers --json)
assert_true jq -e '.providers[] | select(.id=="claude") | .rateLimitedUntilMs > (now * 1000)' <<<"$out"
mk_stub omarchy-agent-usage-claude 'echo called >> "$SWAPKIN_DIR/probe-calls"; echo "{}"'
PATH="$STUBS:$PATH" sk "$SWAPKIN" -p claude usage >/dev/null
assert_true test ! -e "$SWAPKIN_DIR/probe-calls"   # waits for the retry time, never asks
rm -f "$STUBS/omarchy-agent-usage-claude"
rm -f "$SWAPKIN_DIR/work/ratelimit" "$SWAPKIN_DIR/work/ratelimit.until"
out=$(sk "$SWAPKIN" providers --json)
assert_eq "no marker, not rateLimited" "false" "$(jq -r '.providers[] | select(.id=="claude") | .rateLimited' <<<"$out")"

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

echo "21y. every pass logs a start and an end; a collapsed repeat moves its timestamp"
auto_world '{"autoSwitch":false}'
rm -f "$XDG_STATE_HOME/swapkin/check.log"
sk "$SWAPKIN" check >/dev/null
assert_contains "check logs its start" "$(cat "$XDG_STATE_HOME/swapkin/check.log")" "check start"
assert_contains "check logs its end" "$(cat "$XDG_STATE_HOME/swapkin/check.log")" "check end rc=0"
sed -i '$ s/^[^ ]* /2000-01-01T00:00:00 /' "$(AUTOLOG)"
sk "$SWAPKIN" check >/dev/null
assert_true test "$(tail -n 1 "$(AUTOLOG)" | cut -c1-4)" != 2000

echo "21z. the watchdog's own skip note lands in the log; Service.qml keeps the guards"
auto_world '{"autoSwitch":false}'
sk "$SWAPKIN" note "skipped: previous check still running (12s)"
assert_contains "note writes a log line" "$(tail -n 1 "$(AUTOLOG)")" "previous check still running"
svc=$(cat "$ROOT/Service.qml")
assert_contains "Service logs a run skipped for a running one" "$svc" "previous check still running"
assert_contains "Service restarts a stuck run" "$svc" "watchProcess.running = false"
assert_contains "Service starts after an unanswered read" "$svc" "id: loadGuard"

echo "shipped demo data"
shipped=$(SWAPKIN_DEMO=1 SWAPKIN_DEMO_FILE= "$ROOT/bin/swapkin" providers --json 2>&1 || true)
assert_true jq -e '.demo and (.providers | length >= 3) and all(.providers[].accounts[].limits[]; (.resetsAt // "") | test("^[0-9]{4}-") or . == "")' <<<"$shipped"

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
