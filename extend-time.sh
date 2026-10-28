#!/usr/bin/env bash
# Gives extra game time for today by subtracting it from the recorded usage.
# Usage: game-warden-extend-time <user1,user2,...> <minutes>
# Usage may go below zero: "-00:10:00" means 10 minutes more than the daily limit today.

set -euo pipefail

SOURCE="$0"
GW_USERS_ROOT="${GW_USERS_ROOT:-/Users}"

main(){
    # globals SELECTED_USERS
    move_to_original_source_directory
    source shared.inc

    if [[ $# -gt 0 ]]; then
        IFS=, read -a SELECTED_USERS <<< "$1"
    fi

    if [[ ${#SELECTED_USERS[@]} -eq 0 ]]; then
        echo
        echo
        list_users
        prompt_for_users "👤 Enter name of username to extend game time for: "
    fi

    local minutes="${2:-}"
    if [[ -z "$minutes" ]]; then
        read -p "⏱️ Enter number of minutes to add: " minutes
    fi
    if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
        echo "❌ Minutes must be a positive whole number: $minutes"
        exit 1
    fi

    for username in "${SELECTED_USERS[@]}"; do
        if ! sudo test -e "$GW_USERS_ROOT/$username/$LAUNCH_AGENTS_SUBDIR/$PLIST_FILENAME"; then
            echo "ℹ️ $username has no Game Warden installation."
            continue
        fi
        echo "📦 Adding $minutes minutes of game time for $username ..."
        extend_time "$username" "$minutes"
    done
}

extend_time(){
    local username="$1"
    local minutes="$2"
    local homedir="$GW_USERS_ROOT/$username"
    local agent="$homedir/$LAUNCH_AGENTS_SUBDIR/$PLIST_FILENAME"
    local state_file="$homedir/$APP_SUPPORT_SUBDIR/data/usage-state.dat"
    local user_uid
    user_uid="$(id -u "$username")"

    # The running agent keeps the usage in memory and saves it every few seconds,
    # so it has to be stopped while the file is changed.
    sudo launchctl bootout "gui/$user_uid/$PLIST_ID" 2>/dev/null || true

    local daily="00:00:00" weekly="00:00:00"
    if sudo test -e "$state_file"; then
        IFS=, read -r daily weekly < <(sudo cat "$state_file") || true
    fi

    local seconds=$(( minutes * 60 ))
    local new_daily new_weekly
    new_daily="$(seconds_to_time $(( $(time_to_seconds "$daily") - seconds )))"
    new_weekly="$(seconds_to_time $(( $(time_to_seconds "$weekly") - seconds )))"
    # No trailing newline, matching what the agent writes
    printf '%s,%s' "$new_daily" "$new_weekly" | sudo tee "$state_file" > /dev/null

    sudo launchctl bootstrap "gui/$user_uid" "$agent" || true
    echo "✅ Usage today: $daily → $new_daily, this week: $weekly → $new_weekly"
}

time_to_seconds(){
    local time="$1" sign=1 h m s
    if [[ "$time" == -* ]]; then
        sign=-1
        time="${time#-}"
    fi
    IFS=: read -r h m s <<< "$time"
    echo $(( sign * (10#$h * 3600 + 10#$m * 60 + 10#$s) ))
}

seconds_to_time(){
    local total="$1" prefix=""
    if (( total < 0 )); then
        prefix="-"
        total=$(( -total ))
    fi
    printf '%s%02d:%02d:%02d' "$prefix" $(( total / 3600 )) $(( total % 3600 / 60 )) $(( total % 60 ))
}

move_to_original_source_directory(){
    while [ -L "$SOURCE" ]; do
        ORIGINAL_SCRIPT_LOCATION="$(cd -P "$(dirname "$SOURCE")" && pwd)"
        SOURCE="$(readlink "$SOURCE")"
        [[ $SOURCE != /* ]] && SOURCE="$ORIGINAL_SCRIPT_LOCATION/$SOURCE"
    done
    ORIGINAL_SCRIPT_LOCATION="$(cd -P "$(dirname "$SOURCE")" && pwd)"

    # ensure all references are relative to the original script location
    pushd "$ORIGINAL_SCRIPT_LOCATION" > /dev/null
}

main "$@"
