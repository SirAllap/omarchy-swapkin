# shellcheck shell=bash
# shellcheck disable=SC2034  # P_* vars are read by the engine after sourcing this file
# Antigravity (agy) adapter — never mode: agy keeps one sign-in and has no home
# variable to point at another. No p_add/p_use/p_probe: the numbers come from
# Omarchy's collector record (omarchy-agent-usage-agy), not from swapkin.

P_ID=agy
P_NAME=Antigravity
P_MODE=never
P_CMD=agy
P_MARKER=""
P_STORE="the system keyring (service gemini, user antigravity) and ~/.gemini/antigravity-cli; swapkin never reads or copies the token"
P_HOW="Antigravity keeps one sign-in. Switching means signing in again with agy."
P_ADD_HINT="Antigravity keeps one sign-in; swapkin cannot add accounts for it."

p_installed() {
  [[ -n $(tool_bin agy) ]] || [[ -x "$HOME/.local/share/mise/installs/antigravity-cli/latest/agy" ]]
}
p_sessions() { pgrep -x agy 2>/dev/null | wc -l; }

# Listing rule (list with a saved account or own CLI login): true when agy has
# a sign-in, in the Secret Service keyring or in its own file. The keyring
# answer is thrown away (/dev/null); only whether the item exists is used.
p_has_login() {
  [[ -s "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" ]] && return 0
  local st; st=$(tool_bin secret-tool) || return 1
  [[ -n $st ]] || return 1
  "$st" lookup service gemini username antigravity >/dev/null 2>&1
}
