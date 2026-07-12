#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Codex"
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ─────────────────────────────────────────────
color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

pct_icon() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "🔴"
    elif [ "$pct" -ge 70 ]; then printf "🟠"
    elif [ "$pct" -ge 50 ]; then printf "🟡"
    else printf "🟢"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

remaining_time() {
    local epoch=$1
    [ -z "$epoch" ] || [ "$epoch" = "null" ] || [ "$epoch" = "0" ] && return

    local now_epoch
    now_epoch=$(date +%s)
    local diff=$(( epoch - now_epoch ))
    [ "$diff" -le 0 ] && return

    local days=0 hours=0 mins=0
    mins=$(( diff / 60 ))
    if [ "$mins" -ge 1440 ]; then
        days=$(( mins / 1440 ))
        mins=$(( mins % 1440 ))
    fi
    if [ "$mins" -ge 60 ]; then
        hours=$(( mins / 60 ))
        mins=$(( mins % 60 ))
    fi

    local parts=""
    [ "$days" -gt 0 ]  && parts+="${days} day$([ "$days" -gt 1 ] && echo s) "
    [ "$hours" -gt 0 ] && parts+="${hours} hr "
    parts+="${mins} min"

    printf "%s" "$parts"
}

format_epoch_time() {
    local epoch=$1
    local style=$2
    [ -z "$epoch" ] || [ "$epoch" = "null" ] || [ "$epoch" = "0" ] && return

    local result=""
    case "$style" in
        time)
            result=$(date -j -r "$epoch" +"%l:%M%p" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%l:%M%P" 2>/dev/null)
            result=$(echo "$result" | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        datetime)
            result=$(date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null)
            result=$(echo "$result" | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        *)
            result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
            result=$(echo "$result" | tr '[:upper:]' '[:lower:]')
            ;;
    esac
    printf "%s" "$result"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(env TZ=UTC date -d "${stripped/T/ }" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(date -d "${stripped/T/ }" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

# ── Cache helpers ───────────────────────────────────────
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude"
mkdir -p "$cache_dir"

read_cache_if_fresh() {
    local file="$1"
    local max_age="$2"
    [ ! -f "$file" ] && return 1

    local cache_mtime now cache_age
    cache_mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)
    [ -z "$cache_mtime" ] && return 1
    now=$(date +%s)
    cache_age=$(( now - cache_mtime ))
    [ "$cache_age" -ge "$max_age" ] && return 1

    cat "$file" 2>/dev/null
}

# ── Codex model detection ───────────────────────────────
model_name="Codex"

codex_model_cache="$cache_dir/statusline-codex-model-cache.txt"
codex_model=$(read_cache_if_fresh "$codex_model_cache" 300)
if [ -z "$codex_model" ]; then
    if command -v codex >/dev/null 2>&1; then
        codex_model=$(codex doctor --json 2>/dev/null | jq -r '.checks["config.load"].details.model // empty' 2>/dev/null)
        if [ -n "$codex_model" ] && [ "$codex_model" != "null" ]; then
            echo "$codex_model" > "$codex_model_cache"
            model_name="$codex_model"
        fi
    fi
else
    model_name="$codex_model"
fi

# Fall back to stdin model if available
stdin_model=$(echo "$input" | jq -r '.model.display_name // empty')
if [ -n "$stdin_model" ] && [ "$stdin_model" != "null" ]; then
    model_name="$stdin_model"
fi

# ── Extract JSON data (context, cwd, session, effort) ──
size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

effort=$(echo "$input" | jq -r '.effort.level // "default"')

pct_color=$(color_for_pct "$pct_used")
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

session_duration=""
session_start=$(echo "$input" | jq -r '.session.start_time // empty')
if [ -n "$session_start" ] && [ "$session_start" != "null" ]; then
    start_epoch=$(iso_to_epoch "$session_start")
    if [ -n "$start_epoch" ]; then
        now_epoch=$(date +%s)
        elapsed=$(( now_epoch - start_epoch ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi
fi

skip_perms=""
parent_cmd=$(ps -o args= -p "$PPID" 2>/dev/null)
if [[ "$parent_cmd" == *"--dangerously-skip-permissions"* ]]; then
    skip_perms="⚡"
fi

# ── Codex usage via codexbar ───────────────────────────
codex_usage_cache="$cache_dir/statusline-codex-usage-cache.json"

get_codex_usage() {
    local data

    data=$(read_cache_if_fresh "$codex_usage_cache" 60)
    if [ -n "$data" ] && echo "$data" | jq -e '.[0].usage.primary.usedPercent' >/dev/null 2>&1; then
        echo "$data"
        return 0
    fi

    if command -v codexbar >/dev/null 2>&1; then
        data=$(codexbar usage --provider codex --format json --no-color 2>/dev/null)
        if [ -n "$data" ] && echo "$data" | jq -e '.[0].usage.primary.usedPercent' >/dev/null 2>&1; then
            echo "$data" > "$codex_usage_cache"
            echo "$data"
            return 0
        fi
    fi

    if [ -f "$codex_usage_cache" ]; then
        data=$(cat "$codex_usage_cache" 2>/dev/null)
        if [ -n "$data" ] && echo "$data" | jq -e '.[0].usage.primary.usedPercent' >/dev/null 2>&1; then
            echo "$data"
            return 0
        fi
    fi

    return 1
}

# ── Claude OAuth usage (fallback) ──────────────────────
get_oauth_token() {
    local token=""
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        printf "%s" "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi
    if command -v security >/dev/null 2>&1; then
        local blob
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                printf "%s" "$token"
                return 0
            fi
        fi
    fi
    local creds_file="${HOME}/.claude/.credentials.json"
    if [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            printf "%s" "$token"
            return 0
        fi
    fi
    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                printf "%s" "$token"
                return 0
            fi
        fi
    fi
    printf ""
}

claude_usage_cache="$cache_dir/statusline-claude-usage-cache.json"

get_claude_usage() {
    local usage_data response token

    usage_data=$(read_cache_if_fresh "$claude_usage_cache" 60)
    if [ -n "$usage_data" ] && echo "$usage_data" | jq -e '.five_hour' >/dev/null 2>&1; then
        echo "$usage_data"
        return 0
    fi

    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        response=$(curl -s --max-time 5 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
            echo "$response" > "$claude_usage_cache"
            echo "$response"
            return 0
        fi
    fi

    if [ -f "$claude_usage_cache" ]; then
        usage_data=$(cat "$claude_usage_cache" 2>/dev/null)
        if [ -n "$usage_data" ] && echo "$usage_data" | jq -e '.five_hour' >/dev/null 2>&1; then
            echo "$usage_data"
            return 0
        fi
    fi

    return 1
}

# ── Daemon setup (refreshes codexbar cache every 5 min) ─
daemon_pid_file="/tmp/claude/statusline-daemon.pid"
daemon_interval=300
mkdir -p /tmp/claude

start_daemon() {
    [ ! -f "$daemon_pid_file" ] && return

    local pid
    pid=$(cat "$daemon_pid_file" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return
    fi
    rm -f "$daemon_pid_file"

    (
        while true; do
            if command -v codexbar >/dev/null 2>&1; then
                data=$(codexbar usage --provider codex --format json --no-color 2>/dev/null)
                if [ -n "$data" ] && echo "$data" | jq -e '.[0].usage.primary.usedPercent' >/dev/null 2>&1; then
                    echo "$data" > "$codex_usage_cache"
                fi
            fi

            token=$(get_oauth_token)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                response=$(curl -s --max-time 5 \
                    -H "Accept: application/json" \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer $token" \
                    -H "anthropic-beta: oauth-2025-04-20" \
                    -H "User-Agent: claude-code/2.1.34" \
                    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
                if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
                    echo "$response" > "$claude_usage_cache"
                fi
            fi

            sleep "$daemon_interval"
        done
    ) >/dev/null 2>&1 &

    echo $! > "$daemon_pid_file"
}

# ── Resolve usage data ─────────────────────────────────
# Try codexbar first, then Claude OAuth fallback
usage_data=""
usage_provider=""

codex_data=$(get_codex_usage)
if [ -n "$codex_data" ]; then
    usage_data="$codex_data"
    usage_provider="codex"
else
    claude_data=$(get_claude_usage)
    if [ -n "$claude_data" ]; then
        usage_data="$claude_data"
        usage_provider="claude"
    fi
fi

# ── LINE 1: Rate Limits / Usage ─────────────────────────
line1=""
bar_width=10

if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
    if [ "$usage_provider" = "codex" ]; then
        # ── Codex data structure ──
        primary_pct=$(echo "$usage_data" | jq -r '.[0].usage.primary.usedPercent // 0' | awk '{printf "%.0f", $1}')
        primary_reset_iso=$(echo "$usage_data" | jq -r '.[0].usage.primary.resetsAt // empty')
        primary_reset_epoch=$(iso_to_epoch "$primary_reset_iso")
        primary_reset=$(format_epoch_time "$primary_reset_epoch" "time")
        primary_remaining=$(remaining_time "$primary_reset_epoch")
        primary_bar=$(build_bar "$primary_pct" "$bar_width")
        primary_pct_color=$(color_for_pct "$primary_pct")
        primary_pct_fmt=$(printf "%3d" "$primary_pct")
        primary_icon=$(pct_icon "$primary_pct")

        line1+="${white}Current Usage:${reset}  ${primary_bar}${sep}${primary_icon} ${primary_pct_color}${primary_pct_fmt}%${reset}"
        if [ -n "$primary_remaining" ] && [ -n "$primary_reset" ]; then
            line1+="${sep}${white}Resets in:${reset} ${white}${primary_remaining}${reset} ${dim}->${reset} ${white}(${primary_reset})${reset}"
        elif [ -n "$primary_reset" ]; then
            line1+="${sep}${white}Resets at:${reset} ${white}${primary_reset}${reset}"
        fi

        secondary_pct=$(echo "$usage_data" | jq -r '.[0].usage.secondary.usedPercent // 0' | awk '{printf "%.0f", $1}')
        secondary_reset_iso=$(echo "$usage_data" | jq -r '.[0].usage.secondary.resetsAt // empty')
        secondary_reset_epoch=$(iso_to_epoch "$secondary_reset_iso")
        secondary_reset=$(format_epoch_time "$secondary_reset_epoch" "datetime")
        secondary_remaining=$(remaining_time "$secondary_reset_epoch")
        secondary_bar=$(build_bar "$secondary_pct" "$bar_width")
        secondary_pct_color=$(color_for_pct "$secondary_pct")
        secondary_pct_fmt=$(printf "%3d" "$secondary_pct")
        secondary_icon=$(pct_icon "$secondary_pct")

        [ -n "$line1" ] && line1+="${sep}"
        line1+="${white}Weekly Usage:${reset}  ${secondary_bar}${sep}${secondary_icon} ${secondary_pct_color}${secondary_pct_fmt}%${reset}"
        if [ -n "$secondary_remaining" ] && [ -n "$secondary_reset" ]; then
            line1+="${sep}${white}Weekly resets in:${reset} ${white}${secondary_remaining}${reset} ${dim}->${reset} ${white}(${secondary_reset})${reset}"
        elif [ -n "$secondary_reset" ]; then
            line1+="${sep}${white}Weekly resets at:${reset} ${white}${secondary_reset}${reset}"
        fi

        # Reset credits (Codex-specific)
        reset_credits=$(echo "$usage_data" | jq -r '.[0].usage.codexResetCredits.availableCount // empty')
        if [ -n "$reset_credits" ] && [ "$reset_credits" != "null" ]; then
            [ -n "$line1" ] && line1+="${sep}"
            line1+="${white}Reset Credits:${reset} ${green}${reset_credits}${reset} ${dim}available${reset}"
        fi
    else
        # ── Claude OAuth data structure ──
        five_hour_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
        five_hour_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
        five_hour_reset_epoch=$(iso_to_epoch "$five_hour_reset_iso")
        five_hour_reset=$(format_epoch_time "$five_hour_reset_epoch" "time")
        five_hour_remaining=$(remaining_time "$five_hour_reset_epoch")
        five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")
        five_hour_pct_color=$(color_for_pct "$five_hour_pct")
        five_hour_pct_fmt=$(printf "%3d" "$five_hour_pct")
        five_hour_icon=$(pct_icon "$five_hour_pct")

        line1+="${white}Current Usage:${reset}  ${five_hour_bar}${sep}${five_hour_icon} ${five_hour_pct_color}${five_hour_pct_fmt}%${reset}"
        if [ -n "$five_hour_remaining" ] && [ -n "$five_hour_reset" ]; then
            line1+="${sep}${white}Resets in:${reset} ${white}${five_hour_remaining}${reset} ${dim}->${reset} ${white}(${five_hour_reset})${reset}"
        elif [ -n "$five_hour_reset" ]; then
            line1+="${sep}${white}Resets at:${reset} ${white}${five_hour_reset}${reset}"
        fi

        seven_day_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
        seven_day_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
        seven_day_reset_epoch=$(iso_to_epoch "$seven_day_reset_iso")
        seven_day_reset=$(format_epoch_time "$seven_day_reset_epoch" "datetime")
        seven_day_remaining=$(remaining_time "$seven_day_reset_epoch")
        seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")
        seven_day_pct_color=$(color_for_pct "$seven_day_pct")
        seven_day_pct_fmt=$(printf "%3d" "$seven_day_pct")
        seven_day_icon=$(pct_icon "$seven_day_pct")

        [ -n "$line1" ] && line1+="${sep}"
        line1+="${white}Weekly Usage:${reset}  ${seven_day_bar}${sep}${seven_day_icon} ${seven_day_pct_color}${seven_day_pct_fmt}%${reset}"
        if [ -n "$seven_day_remaining" ] && [ -n "$seven_day_reset" ]; then
            line1+="${sep}${white}Weekly resets in:${reset} ${white}${seven_day_remaining}${reset} ${dim}->${reset} ${white}(${seven_day_reset})${reset}"
        elif [ -n "$seven_day_reset" ]; then
            line1+="${sep}${white}Weekly resets at:${reset} ${white}${seven_day_reset}${reset}"
        fi

        extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
        if [ "$extra_enabled" = "true" ]; then
            extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
            extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
            extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')
            extra_bar=$(build_bar "$extra_pct" "$bar_width")
            extra_pct_color=$(color_for_pct "$extra_pct")
            extra_icon=$(pct_icon "$extra_pct")

            extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            if [ -z "$extra_reset" ]; then
                extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            fi

            [ -n "$line1" ] && line1+="${sep}"
            line1+="${white}Extra Usage:${reset}  ${extra_bar}${sep}${extra_icon} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset}"
            line1+="${sep}${white}Resets at:${reset} ${white}${extra_reset}${reset}"
        fi
    fi
fi

# ── LINE 2: Model │ Context │ Directory │ Effort │ Session ──
line2=""

line2+="${white}Model in use:${reset} ${blue}${model_name}${reset}"
line2+="${sep}"

line2+="${white}Context:${reset} ${pct_color}✍️ ${pct_used}%${reset}"
line2+="${sep}"

line2+="${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line2+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
line2+="${sep}"

case "$effort" in
    high)   line2+="${white}Effort:${reset} ${red}🔥${reset} ${magenta}high${reset}" ;;
    medium) line2+="${white}Effort:${reset} ${yellow}⚡${reset} ${yellow}medium${reset}" ;;
    low)    line2+="${white}Effort:${reset} ${green}🐢${reset} ${green}low${reset}" ;;
    xhigh)  line2+="${white}Effort:${reset} ${red}💥${reset} ${red}xhigh${reset}" ;;
    max)    line2+="${white}Effort:${reset} ${red}🌋${reset} ${red}max${reset}" ;;
    *)      line2+="${white}Effort:${reset} ${white}⚪${reset} ${white}default${reset}" ;;
esac

if [ -n "$session_duration" ]; then
    line2+="${sep}"
    line2+="${white}⏱${reset} ${white}${session_duration}${reset}"
fi

# ── Output ──────────────────────────────────────────────
[ -n "$line1" ] && printf "%b" "$line1"
[ -n "$line1" ] && [ -n "$line2" ] && printf "\n"
printf "%b" "$line2"

exit 0
