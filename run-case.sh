#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
    printf 'Usage: %s {oom-before|oom-after|cpu-before|cpu-after|deadlock-before|deadlock-after}\n' "${0##*/}" >&2
}

case_name="${1:-}"
case "$case_name" in
    oom-before) memory_limit=50; cpu_limit=100; multi_thread=false ;;
    oom-after) memory_limit=100; cpu_limit=100; multi_thread=false ;;
    cpu-before) memory_limit=512; cpu_limit=100; multi_thread=false ;;
    cpu-after) memory_limit=512; cpu_limit=10; multi_thread=false ;;
    deadlock-before) memory_limit=512; cpu_limit=10; multi_thread=true ;;
    deadlock-after) memory_limit=512; cpu_limit=10; multi_thread=false ;;
    *) usage; exit 2 ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -m)" in
    aarch64 | arm64) app_binary="$script_dir/agent-leak-app-arm64" ;;
    x86_64 | amd64) app_binary="$script_dir/agent-leak-app-x86" ;;
    *) printf '[ERROR] Unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

[[ -x "$app_binary" ]] || {
    printf '[ERROR] Executable not found: %s\n' "$app_binary" >&2
    exit 1
}

agent_home="${AGENT_HOME:-$script_dir/.agent-home}"
upload_dir="$agent_home/upload_files"
key_dir="$agent_home/api_keys"
log_dir="$agent_home/logs"

install -d -m 0750 "$agent_home" "$upload_dir" "$key_dir" "$log_dir"
if [[ ! -f "$key_dir/secret.key" ]]; then
    (umask 0077; printf '%s\n' 'agent_api_key_test' >"$key_dir/secret.key")
fi

printf 'Case=%s MEMORY_LIMIT=%s CPU_MAX_OCCUPY=%s MULTI_THREAD_ENABLE=%s\n' \
    "$case_name" "$memory_limit" "$cpu_limit" "$multi_thread"

export AGENT_HOME="$agent_home"
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="$upload_dir"
export AGENT_KEY_PATH="$key_dir"
export AGENT_LOG_DIR="$log_dir"
export MEMORY_LIMIT="$memory_limit"
export CPU_MAX_OCCUPY="$cpu_limit"
export MULTI_THREAD_ENABLE="$multi_thread"

exec "$app_binary"
