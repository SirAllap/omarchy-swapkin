# shellcheck shell=bash
# shellcheck disable=SC2034  # P_* vars are read by the engine after sourcing this file
# Copilot CLI adapter — cold, backed by gh's own account switch. A login made
# with `copilot login` directly (not through gh) is not touched by `use`.

P_ID=copilot
P_NAME=Copilot
P_MODE=cold
P_CMD=copilot
P_MARKER=copilot.json
P_STORE="gh's per-host auth (github.com)"
P_HOW="Switching runs gh auth switch; new Copilot CLI sessions pick it up, open ones keep their token. A login made with 'copilot login' directly is not switched. It also changes which user gh's git credential helper uses (for example on git push)."
P_ADD_HINT="The first account is gh's current active user."
# use must always run gh auth switch, never short-circuit on "already on"
# (M9): the stored active pointer can disagree with gh's real active user
# when someone runs `gh auth switch` by hand.
P_ALWAYS_SWITCH=1

p_installed() { [[ -n $(tool_bin gh) ]]; }
p_sessions() { pgrep -x copilot 2>/dev/null | wc -l; }

gh_hosts_json() {
  local gh; gh=$(tool_bin gh)
  [[ -n $gh ]] || { echo '{}'; return; }
  "$gh" auth status --json hosts 2>/dev/null || echo '{}'
}

login_of() { jq -r '.user // empty' "$(account_dir "$1")/copilot.json" 2>/dev/null; } # name

# M9: Copilot's "active" account is derived from gh's real active login at
# read time, not from swapkin's stored pointer, which can drift the moment
# someone runs `gh auth switch` by hand outside swapkin.
p_active() {
  local login; login=$(jq -r '.hosts["github.com"][]? | select(.active) | .login' <<<"$(gh_hosts_json)" | head -1)
  if [[ -z $login ]]; then
    cat "$(provider_active_file "$P_ID")" 2>/dev/null || true
    return
  fi
  local name
  for name in $(profiles); do
    [[ $(login_of "$name") == "$login" ]] && { echo "$name"; return; }
  done
  return 0
}

mapped_logins() { # already-saved gh logins, as a JSON array
  local name arr='[]'
  for name in $(profiles); do
    arr=$(jq -c --argjson a "$arr" --arg u "$(login_of "$name")" '$a + [$u]' <<<"$arr")
  done
  echo "$arr"
}

p_add() { # name [gh-login]
  local name="${1:?usage: swapkin -p copilot add <name> [gh-login]}" user="${2:-}"
  valid_name "$name"
  local dir; dir=$(account_dir "$name")
  [[ -e $dir/copilot.json ]] && die "'$name' already exists"
  local gh; gh=$(tool_bin gh)
  [[ -n $gh ]] || die "cannot find the gh command"
  local hosts; hosts=$(gh_hosts_json)
  local login=""

  if [[ -z $(profiles) ]]; then
    login=$(jq -r '.hosts["github.com"][]? | select(.active) | .login' <<<"$hosts" | head -1)
    [[ -n $login ]] || die "gh has no active github.com login; run: gh auth login --hostname github.com --web --git-protocol https"
  elif [[ -n $user ]]; then
    jq -e --arg u "$user" '.hosts["github.com"][]? | select(.login==$u)' <<<"$hosts" >/dev/null 2>&1 \
      || die "gh does not know user '$user'"
    login="$user"
  else
    local mapped candidates
    mapped=$(mapped_logins)
    candidates=$(jq -r --argjson mapped "$mapped" '.hosts["github.com"][]? | .login | select(. as $l | ($mapped | index($l)) | not)' <<<"$hosts")
    local n; n=$(grep -c . <<<"$candidates" 2>/dev/null || echo 0)
    if [[ -z $candidates ]]; then
      die "run: gh auth login --hostname github.com --web --git-protocol https, then: swapkin -p copilot add $name"
    elif (( n == 1 )); then
      login="$candidates"
    else
      die "several gh users are not mapped yet; pass one: swapkin -p copilot add $name <login>"
    fi
  fi

  mkdir -p "$dir"
  jq -n --arg user "$login" '{user:$user}' > "$dir/copilot.json.tmp"
  mv "$dir/copilot.json.tmp" "$dir/copilot.json"
  set_colour "$name" "$(next_colour "$name")"
  [[ -z $(active) ]] && set_active "$name"
  echo "Saved '$name' (gh user $login)."
}

p_use() { # name
  local name="$1" dir; dir=$(account_dir "$name")
  [[ -f $dir/copilot.json ]] || die "no saved account '$name'"
  local login; login=$(login_of "$name")
  [[ -n $login ]] || die "'$name' has no saved gh user"
  local gh; gh=$(tool_bin gh)
  [[ -n $gh ]] || die "cannot find the gh command"
  "$gh" auth switch --hostname github.com --user "$login" >/dev/null
  set_active "$name"
  echo "Active: $name (gh switched to $login)"
}

plan_label() { # plan sku
  case "$2" in
    free_limited_copilot) echo "Free"; return ;;
    individual) echo "Pro"; return ;;
    business) echo "Business"; return ;;
    enterprise) echo "Enterprise"; return ;;
  esac
  echo "${1:-$2}"
}

p_probe() { # name
  local name="$1" dir; dir=$(account_dir "$name")
  local login; login=$(login_of "$name")
  [[ -n $login ]] || return 0
  local gh; gh=$(tool_bin gh)
  [[ -n $gh ]] || return 0
  # Token goes to the child's environment only, never argv.
  local token; token=$("$gh" auth token --hostname github.com --user "$login" 2>/dev/null) || return 0
  [[ -n $token ]] || return 0
  local record
  record=$(GH_TOKEN="$token" timeout 20 "$gh" api /copilot_internal/user 2>/dev/null) || return 0
  jq -e . >/dev/null 2>&1 <<<"$record" || return 0

  local limits='[]' counts='[]' key label
  # GitHub gives one reset date for the whole account, next to the snapshots.
  local reset; reset=$(jq -r '.quota_reset_date_utc // empty' <<<"$record")
  for key in premium_interactions chat completions; do
    local node; node=$(jq -c --arg k "$key" '.quota_snapshots[$k] // empty' <<<"$record")
    [[ -n $node && $node != null ]] || continue
    case "$key" in
      premium_interactions) label="Premium requests · month" ;;
      chat) label="Chat · month" ;;
      completions) label="Completions · month" ;;
    esac
    local has_quota unlimited entitlement remaining
    IFS=$'\t' read -r has_quota unlimited entitlement remaining <<<"$(jq -r \
      '[(.has_quota), (.unlimited), (.entitlement // 0), (.remaining // 0)] | @tsv' <<<"$node")"
    if [[ $unlimited == true ]]; then
      counts=$(jq -c --argjson counts "$counts" --arg label "${label%% ·*}" -n '$counts + [{label:$label, value:"unlimited"}]')
    elif [[ $has_quota == true ]] && awk -v e="$entitlement" 'BEGIN{exit !(e>0)}'; then
      limits=$(jq -c --argjson limits "$limits" --arg label "$label" --argjson entitlement "$entitlement" \
        --argjson remaining "$remaining" --arg resets "$reset" -n \
        '($entitlement - $remaining) as $used
         | $limits + [{label:$label, percent: ($used / $entitlement), used:$used,
                        limit:$entitlement, unit:"requests", resetsAt:$resets}]')
    fi
  done

  local plan_raw sku
  IFS=$'\t' read -r plan_raw sku <<<"$(jq -r '[(.copilot_plan // ""), (.access_type_sku // "")] | @tsv' <<<"$record")"
  local plan; plan=$(plan_label "$plan_raw" "$sku")
  jq -n --argjson limits "$limits" --argjson counts "$counts" --arg plan "$plan" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{limits:$limits, counts:$counts, tierLabel:$plan, note:"", updatedAt:$updated}' > "$dir/usage.json.tmp"
  mv "$dir/usage.json.tmp" "$dir/usage.json"
}

p_plan() { jq -r '.tierLabel // empty' "$(account_dir "$1")/usage.json" 2>/dev/null; }
