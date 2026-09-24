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

# Custom providers can only touch files under $HOME: nothing under the repo,
# nothing system-wide, nothing an invented entry could point somewhere unsafe.
under_home() { # path
  local p home
  p=$(readlink -f -m "$1" 2>/dev/null || echo "$1")
  home=$(readlink -f -m "$HOME")
  # An exact match, or a "$home/" prefix (L2): a bare string-prefix test
  # would also accept a sibling directory like /home/u2 for HOME=/home/u.
  [[ $p == "$home" || $p == "$home"/* ]] || die "custom provider path '$1' must resolve under \$HOME"
  echo "$p"
}

login_files() { jq -r '.loginFiles[]? // empty' <<<"$_CUSTOM_ENTRY"; }

# One hash standing in for "the live login files as a whole", so `add` can
# tell a fresh sign-in apart from the login that was there before it started
# (H1: a missing file hashes to a fixed marker, not silence).
live_files_hash() {
  local f real out=""
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    real=$(under_home "$(expand_path "$f")")
    if [[ -f $real ]]; then
      out+="$(sha256sum "$real" 2>/dev/null | cut -d' ' -f1)"
    else
      out+="missing:$f"
    fi
  done < <(login_files)
  printf '%s' "$out" | sha256sum | cut -d' ' -f1
}

home_of() { jq -r '.home // empty' "$(account_dir "$1")/custom.json" 2>/dev/null; } # name

p_installed() { [[ -n $(tool_bin "$P_CMD") ]]; }
p_sessions() { pgrep -x "$P_CMD" 2>/dev/null | wc -l; }

# hot only: copy the live files back into whichever account is active now.
p_save() {
  [[ $P_MODE == hot ]] || return 0
  local name; name=$(active)
  [[ -n $name ]] || return 0
  local dir; dir=$(account_dir "$name")
  mkdir -p "$dir/files"
  local i=0 f
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    local real; real=$(under_home "$(expand_path "$f")")
    if [[ -f $real ]]; then
      local tmp; tmp=$(mktemp "$dir/files/$i.XXXXXX")
      cp "$real" "$tmp"
      mv "$tmp" "$dir/files/$i"
    fi
    i=$((i + 1))
  done < <(login_files)
}

p_add() { # name
  local name="${1:?usage: swapkin -p $P_ID add <name>}"
  valid_name "$name"
  local dir; dir=$(account_dir "$name")
  [[ -e $dir/custom.json ]] && die "'$name' already exists"

  if [[ $P_MODE == hot ]]; then
    if [[ -z $(profiles) ]]; then
      # First account: nothing saved yet to save back into. Capture whatever
      # is live now.
      mkdir -p "$dir/files"
      local i=0 f
      while IFS= read -r f; do
        [[ -n $f ]] || continue
        local real; real=$(under_home "$(expand_path "$f")")
        [[ -f $real ]] || die "no live file at $f; sign in with $P_CMD first, then run add"
        cp "$real" "$dir/files/$i"
        i=$((i + 1))
      done < <(login_files)
      mkdir -p "$dir"
      jq -n '{mode:"hot"}' > "$dir/custom.json.tmp"
      mv "$dir/custom.json.tmp" "$dir/custom.json"
      set_colour "$name" "$(next_colour "$name")"
      set_active "$name"
      echo "Saved '$name'."
      return
    fi

    # Later accounts (H1): save the currently-active account's live login
    # back into ITS OWN profile first, before telling the user anything —
    # p_save must never run after the user has already signed in as the new
    # account, or the new login gets filed under the old name. Only once
    # that is safely stored do we ask for a new sign-in and wait for the
    # live files to actually change before capturing them as NAME.
    p_save
    local before; before=$(live_files_hash)
    echo "$P_NAME: sign in as '$name' now. This returns on its own once the login changes."
    local waited=0
    while (( waited < 900 )); do
      [[ $(live_files_hash) != "$before" ]] && break
      sleep 1
      waited=$((waited + 1))
    done
    [[ $(live_files_hash) != "$before" ]] || fail "no sign-in change seen after 900s, so nothing was saved."

    mkdir -p "$dir/files"
    local i=0 f
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      local real; real=$(under_home "$(expand_path "$f")")
      [[ -f $real ]] || die "no live file at $f after signing in"
      cp "$real" "$dir/files/$i"
      i=$((i + 1))
    done < <(login_files)
    mkdir -p "$dir"
    jq -n '{mode:"hot"}' > "$dir/custom.json.tmp"
    mv "$dir/custom.json.tmp" "$dir/custom.json"
    set_colour "$name" "$(next_colour "$name")"
    set_active "$name"
    echo "Saved '$name'."
    return
  fi

  # cold
  local env_key; env_key=$(jq -r '.homeEnv' <<<"$_CUSTOM_ENTRY")
  local default_home; default_home=$(under_home "$(expand_path "$(jq -r '.defaultHome' <<<"$_CUSTOM_ENTRY")")")
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

  if [[ $P_MODE == hot ]]; then
    [[ -n $(active) ]] && p_save

    # M1: verify every saved copy in the profile AND every corresponding
    # live file exist BEFORE replacing anything. A partial swap (file 0
    # replaced, file 1 missing) would leave the live login mixed between
    # two accounts with the active pointer still pointing at the old one.
    local i=0 f real
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      real=$(under_home "$(expand_path "$f")")
      [[ -f $dir/files/$i ]] || die "'$name' has no saved copy of $f; nothing changed"
      [[ -f $real ]] || die "no live file at $f; nothing changed"
      i=$((i + 1))
    done < <(login_files)

    i=0
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      real=$(under_home "$(expand_path "$f")")
      local tmp; tmp=$(mktemp "$real.XXXXXX")
      cp "$dir/files/$i" "$tmp"
      chmod --reference="$real" "$tmp" 2>/dev/null || true
      mv "$tmp" "$real"
      i=$((i + 1))
    done < <(login_files)
    set_active "$name"
    echo "Active: $name"
    return
  fi

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
