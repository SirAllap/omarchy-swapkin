# shellcheck shell=bash
# Generic adapter for a user-defined provider, driven by one entry in
# ~/.config/swapkin/providers.json. P_ID/P_NAME/P_MODE/P_CMD/P_STORE/P_HOW/
# P_ADD_HINT and $_CUSTOM_ENTRY are set by the engine's load_adapter() before
# this file is sourced.

expand_path() { # path (may start with ~)
  local p="$1"
  [[ $p == "~"* ]] && p="$HOME${p:1}"
  echo "$p"
}

# defaultHome comes from providers.json, so it is checked before it is
# trusted: it must resolve under $HOME. This is a read-side check only —
# custom providers are cold-only, and a cold provider never writes to
# defaultHome; swapkin only stores the resolved string in custom.json and
# hands it to the tool through homeEnv. Every write below lands in
# provider_root/account_dir, which swapkin owns. (Hot mode, which overwrites
# a live login file at a user-supplied path, is kept to the built-in
# providers: that write could not be made safe against an ancestor swapped
# for a symlink between check and write in bash. See docs/providers.md.)
resolve_under_home() { # path
  local real root
  real=$(readlink -f -m -- "$1")
  root=$(readlink -f -- "$HOME")
  [[ $real == "$root"/* ]] || die "custom provider path '$1' must resolve under \$HOME"
  echo "$real"
}

home_of() { jq -r '.home // empty' "$(account_dir "$1")/custom.json" 2>/dev/null; } # name

p_installed() { [[ -n $(tool_bin "$P_CMD") ]]; }
p_sessions() { pgrep -x "$P_CMD" 2>/dev/null | wc -l; }

p_add() { # name
  local name="${1:?usage: swapkin -p $P_ID add <name>}"
  valid_name "$name"
  local dir; dir=$(account_dir "$name")
  [[ -e $dir/custom.json ]] && die "'$name' already exists"

  local env_key; env_key=$(jq -r '.homeEnv' <<<"$_CUSTOM_ENTRY")
  local default_home; default_home=$(resolve_under_home "$(expand_path "$(jq -r '.defaultHome' <<<"$_CUSTOM_ENTRY")")") || exit 1
  if [[ -z $(profiles) ]]; then
    mkdir -p "$dir"
    jq -n --arg home "$default_home" '{mode:"cold", home:$home}' > "$dir/custom.json.tmp"
    mv "$dir/custom.json.tmp" "$dir/custom.json"
    set_colour "$name" "$(next_colour "$name")"
    set_active "$name"
    echo "Saved the current $P_NAME login as '$name'."
    return
  fi
  local home; home="$(provider_root "$P_ID")/$name/home"
  mkdir -p "$home"
  local login_cmd; login_cmd=$(jq -r '.loginCommand // empty' <<<"$_CUSTOM_ENTRY")
  if [[ -n $login_cmd ]]; then
    echo "$P_NAME opens to sign in. Complete the flow; this returns once it's done."
    # --foreground: without it, timeout puts the child in its own background
    # process group and an interactive sign-in can't read the terminal (M4).
    env "$env_key=$home" timeout --foreground 300 bash -c "$login_cmd" || true
    # Don't trust the login command's exit code alone: confirm the home
    # actually gained something before calling it "Saved" (M4).
    local got; got=$(find "$home" -type f 2>/dev/null | head -1)
    [[ -n $got ]] || fail "no sign-in found in $home, so nothing was saved."
  fi
  mkdir -p "$dir"
  jq -n --arg home "$home" '{mode:"cold", home:$home}' > "$dir/custom.json.tmp"
  mv "$dir/custom.json.tmp" "$dir/custom.json"
  set_colour "$name" "$(next_colour "$name")"
  echo "Saved '$name'. Switch with: swapkin -p $P_ID use $name"
}

p_use() { # name
  local name="$1" dir; dir=$(account_dir "$name")
  [[ -f $dir/custom.json ]] || die "no saved account '$name'"
  local home; home=$(home_of "$name")
  [[ -n $home ]] || die "'$name' has no saved home"
  set_active "$name"
  echo "New $P_NAME sessions use $name. Open ones keep their account. Run: eval \"\$(swapkin env $P_ID)\""
}

p_env() { # name
  [[ $P_MODE == cold ]] || return 0
  local home; home=$(home_of "$1")
  [[ -n $home ]] || return 0
  local env_key; env_key=$(jq -r '.homeEnv' <<<"$_CUSTOM_ENTRY")
  echo "$env_key=$home"
}

p_probe() { # name
  local name="$1" dir; dir=$(account_dir "$name")
  local cmd; cmd=$(jq -r '.usageCommand // empty' <<<"$_CUSTOM_ENTRY")
  [[ -n $cmd ]] || return 0
  local envs=("SWAPKIN_PROFILE=$dir")
  if [[ $P_MODE == cold ]]; then
    local home env_key; home=$(home_of "$name")
    env_key=$(jq -r '.homeEnv' <<<"$_CUSTOM_ENTRY")
    [[ -n $home ]] && envs+=("$env_key=$home")
  fi
  local record
  record=$(env "${envs[@]}" timeout 20 bash -c "$cmd" 2>/dev/null) || return 0
  # Only accept the documented shape: a JSON object with limits and counts
  # arrays. Anything else (an array, a string, a number, a malformed object)
  # is rejected and the last good usage.json is kept.
  jq -e 'type == "object" and (.limits | type) == "array" and (.counts | type) == "array"' \
    >/dev/null 2>&1 <<<"$record" || return 0
  echo "$record" > "$dir/usage.json.tmp"
  mv "$dir/usage.json.tmp" "$dir/usage.json"
}

p_plan() { jq -r '.tierLabel // empty' "$(account_dir "$1")/usage.json" 2>/dev/null; }
