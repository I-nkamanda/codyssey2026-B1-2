#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

interval="${1:-1}"
sample_count="${2:-1}"
process_pattern="${AGENT_PROCESS_PATTERN:-agent-leak-app}"
agent_port="${AGENT_PORT:-15034}"
monitor_log="${MONITOR_LOG_FILE:-./monitor.log}"

[[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '[ERROR] interval must be a non-negative number\n' >&2; exit 2; }
[[ "$sample_count" =~ ^[1-9][0-9]*$ ]] || { printf '[ERROR] sample count must be a positive integer\n' >&2; exit 2; }
[[ "$agent_port" =~ ^[0-9]+$ ]] && (( agent_port >= 1 && agent_port <= 65535 )) || { printf '[ERROR] AGENT_PORT must be between 1 and 65535\n' >&2; exit 2; }

for required_command in pgrep ps awk df date; do
    command -v "$required_command" >/dev/null 2>&1 || { printf '[ERROR] required command not found: %s\n' "$required_command" >&2; exit 1; }
done

sample_once() {
    local timestamp pids worker_pid process_row cpu mem rss_kb rss_mb threads state
    local port_state disk_used mem_total_kb mem_available_kb system_mem_used

    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    pids="$(pgrep -f -- "$process_pattern" 2>/dev/null || true)"
    if [[ -z "$pids" ]]; then
        printf '[%s] PROCESS:%s STATUS:not-running\n' "$timestamp" "$process_pattern"
        return 1
    fi

    worker_pid="$({
        for process_id in $pids; do ps -p "$process_id" -o pid=,rss= 2>/dev/null || true; done
    } | awk 'NF == 2 && $2 > max { max=$2; pid=$1 } END { print pid }')"
    [[ -n "$worker_pid" ]] || return 1

    process_row="$(ps -p "$worker_pid" -o %cpu=,%mem=,rss=,nlwp=,stat= 2>/dev/null | awk '{$1=$1; print}')"
    read -r cpu mem rss_kb threads state <<<"$process_row"
    rss_mb="$(awk -v value="$rss_kb" 'BEGIN { printf "%.1f", value / 1024 }')"

    if command -v ss >/dev/null 2>&1 && ss -ltnH 2>/dev/null | awk -v port="$agent_port" '{address=$4; sub(/^.*:/,"",address); if (address==port) found=1} END {exit !found}'; then
        port_state=LISTEN
    else
        port_state=closed
    fi

    disk_used="$(df -P / | awk 'NR == 2 {print $5}')"
    mem_total_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
    mem_available_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
    if [[ -n "$mem_total_kb" && -n "$mem_available_kb" ]]; then
        system_mem_used="$(awk -v total="$mem_total_kb" -v available="$mem_available_kb" 'BEGIN {printf "%.1f%%", (total-available)*100/total}')"
    else
        system_mem_used=unknown
    fi

    printf '[%s] PROCESS:%s PID:%s CPU:%s%% MEM:%s%% RSS:%sMB THREADS:%s STATE:%s PORT:%s:%s DISK_USED:%s SYSTEM_MEM:%s\n' \
        "$timestamp" "$process_pattern" "$worker_pid" "$cpu" "$mem" "$rss_mb" "$threads" "$state" "$agent_port" "$port_state" "$disk_used" "$system_mem_used"
}

mkdir -p -- "$(dirname -- "$monitor_log")"
for ((sample_index = 1; sample_index <= sample_count; sample_index++)); do
    sample_line="$(sample_once || true)"
    printf '%s\n' "$sample_line" | tee -a "$monitor_log"
    (( sample_index < sample_count )) && sleep "$interval"
done
