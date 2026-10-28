#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT

users_root="$temp_root/users"
stub_bin="$temp_root/bin"
sudo_log="$temp_root/sudo.log"
august_data="$users_root/august/Library/Application Support/game-warden/data"
oskar_data="$users_root/oskar/Library/Application Support/game-warden/data"
mkdir -p "$august_data" "$users_root/august/Library/LaunchAgents" "$oskar_data" "$stub_bin"
touch "$users_root/august/Library/LaunchAgents/no.kopseng.game-warden.plist"
printf '00:50:10,04:10:00' > "$august_data/usage-state.dat"
printf '00:10:00,00:10:00' > "$oskar_data/usage-state.dat"

# Runs file commands for real, only logs launchctl
cat > "$stub_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SUDO_LOG"
[[ "$1" == launchctl ]] && exit 0
"$@"
EOF
cat > "$stub_bin/id" <<'EOF'
#!/usr/bin/env bash
echo 501
EOF
chmod +x "$stub_bin/sudo" "$stub_bin/id"

run(){
    GW_USERS_ROOT="$users_root" SUDO_LOG="$sudo_log" PATH="$stub_bin:$PATH" \
        "$script_dir/extend-time.sh" "$@"
}

fail(){
    echo "$1" >&2
    exit 1
}

output="$(run august,oskar 30)"
expected=$'📦 Adding 30 minutes of game time for august ...\n✅ Usage today: 00:50:10 → 00:20:10, this week: 04:10:00 → 03:40:00\nℹ️ oskar has no Game Warden installation.'
[[ "$output" == "$expected" ]] || fail "unexpected output:"$'\n'"$output"

[[ "$(cat "$august_data/usage-state.dat")" == "00:20:10,03:40:00" ]] || \
    fail "unexpected state: $(cat "$august_data/usage-state.dat")"
[[ "$(cat "$oskar_data/usage-state.dat")" == "00:10:00,00:10:00" ]] || fail 'oskar state must not change'

grep -Fxq "launchctl bootout gui/501/no.kopseng.game-warden" "$sudo_log" || fail 'agent must be stopped'
grep -Fxq "launchctl bootstrap gui/501 $users_root/august/Library/LaunchAgents/no.kopseng.game-warden.plist" "$sudo_log" || \
    fail 'agent must be started again'

# More time than played so far makes the usage negative
run august 30 > /dev/null
[[ "$(cat "$august_data/usage-state.dat")" == "-00:09:50,03:10:00" ]] || \
    fail "usage must go negative: $(cat "$august_data/usage-state.dat")"
run august 60 > /dev/null
[[ "$(cat "$august_data/usage-state.dat")" == "-01:09:50,02:10:00" ]] || \
    fail "negative usage must be read back: $(cat "$august_data/usage-state.dat")"

# Missing state file counts as no usage
rm "$august_data/usage-state.dat"
run august 10 > /dev/null
[[ "$(cat "$august_data/usage-state.dat")" == "-00:10:00,-00:10:00" ]] || fail 'missing state must be handled'

if run august abc > /dev/null; then
    fail 'invalid minutes must be rejected'
fi

echo 'extend-time test passed'
