#!/usr/bin/env bash

set -Eeuo pipefail #monitor.sh와 같은 강력한 bash script 설정.

usage() { # 사용법을 출력하는 함수로, 스크립트가 잘못된 인자를 받았을 때 호출된다.
    printf 'Usage: %s {oom-before|oom-after|cpu-before|cpu-after|deadlock-before|deadlock-after}\n' "${0##*/}" >&2
}

case_name="${1:-}" #테스트 케이스로 인정하는 인자는 1개만 받으며, 기본값은 없다. (${1:-}는 첫 번째 인자($1)가 없으면 빈 문자열을 사용한다는 의미이다.)
case "$case_name" in #7가지 테스트 케이스에 따라 메모리 제한, CPU 제한, 멀티스레드 여부를 설정한다.
    oom-before) memory_limit=50; cpu_limit=100; multi_thread=false ;; #예시: oom-before는 메모리 제한 = 50MB, CPU 제한 = 100%, 멀티스레드 사용 안함
    oom-after) memory_limit=100; cpu_limit=100; multi_thread=false ;;
    cpu-before) memory_limit=512; cpu_limit=100; multi_thread=false ;;
    cpu-after) memory_limit=512; cpu_limit=10; multi_thread=false ;;
    deadlock-before) memory_limit=512; cpu_limit=10; multi_thread=true ;;
    deadlock-after) memory_limit=512; cpu_limit=10; multi_thread=false ;;
    *) usage; exit 2 ;; #6가지 테스트 케이스 이외의 인자에는 위에 명시된 usage 함수를 출력 후 2를 반환하고 종료한다. 
esac # if-fi 구문과 같이 case-esac 구문은 조건문을 처리하는 구문이다. case "$case_name" in 은 case_name 변수의 값에 따라 여러 패턴을 비교하고, 일치하는 패턴이 있으면 해당 블록을 실행한다. 각 패턴은 )로 끝나며, ;;로 블록을 종료한다. 마지막 * 패턴은 모든 경우에 해당하니, 윗 케이스에 걸리지 않은 모든 케이드 = else 처럼 작동하는 것이다.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" # 스크립트가 있는 디렉토리 경로를 가져온다. BASH_SOURCE[0]는 현재 스크립트의 경로를 나타내며, dirname은 해당 경로에서 디렉토리 부분만 추출한다. cd -- "$(dirname -- "${BASH_SOURCE[0]}")"는 해당 디렉토리로 이동하고, pwd는 현재 디렉토리의 절대 경로를 출력한다. $(...)는 명령어 치환(command substitution)으로, 내부 명령어의 출력을 외부 명령어의 인자로 사용할 수 있게 한다.
case "$(uname -m)" in # uname - m 명령어로 현재 시스템의 아키텍쳐를 불러와서 아래의 case와 비교해 본다.
    aarch64 | arm64) app_binary="$script_dir/agent-leak-app-arm64" ;; #애플 실리콘과 같은 arm64면 agent-leak-app-arm64를 실행한다.
    x86_64 | amd64) app_binary="$script_dir/agent-leak-app-x86" ;; #인텔의 경우에는 agent-leak-app-x86를 실행한다.
    *) printf '[ERROR] Unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;; #둘 다 아니라면 실행해줄 agent-leak-app이 없으므로 에러! 코드 1로 탈출한다.
esac

[[ -x "$app_binary" ]] || { #app_binary가 실행 가능한 파일인지 확인한다. -x 옵션은 파일이 존재하고 실행 가능한지 확인하는 옵션이다. 만약 실행 불가능하면 에러 메시지를 출력하고 종료한다.
    printf '[ERROR] Executable not found: %s\n' "$app_binary" >&2 #실행할 수 있는 파일이 없네요 메시지를 출력하고 거기에 수반되는 메시지는 표준 에러(stderr)로 출력한다. >&2는 표준 에러로 출력하라는 의미이다.
    exit 1 #코드 1을 내뱉고 종료.
}

agent_home="${AGENT_HOME:-$script_dir/.agent-home}" #agent_home은 AGENT_HOME 환경 변수가 설정되어 있으면 그 값을 사용하고, 그렇지 않으면 script_dir/.agent-home을 사용한다. ${AGENT_HOME:-$script_dir/.agent-home}는 AGENT_HOME이 설정되어 있지 않으면 $script_dir/.agent-home을 기본값으로 사용한다는 의미이다.
upload_dir="$agent_home/upload_files" #업로드 디렉토리로는 agent_home/upload_files를 사용한다.
key_dir="$agent_home/api_keys" #키 디렉토리도 맞게 설정해 주고
log_dir="$agent_home/logs" # 로그 디렉토리도 맞게 설정해 준다.

install -d -m 0750 "$agent_home" "$upload_dir" "$key_dir" "$log_dir" #install 명령어를 사용하여 agent_home, upload_dir, key_dir, log_dir 디렉토리를 생성한다. -d 옵션은 디렉토리를 생성하라는 의미이고, -m 0750 옵션은 생성된 디렉토리의 권한을 0750으로 설정한다. 0750 권한은 소유자는 읽기, 쓰기, 실행 권한을 가지며, 그룹은 읽기 및 실행 권한을 가지며, 다른 사용자들은 접근할 수 없다는 의미이다.
if [[ ! -f "$key_dir/secret.key" ]]; then #secret.key 파일이 존재하지 않으면
    (umask 0077; printf '%s\n' 'agent_api_key_test' >"$key_dir/secret.key") # umask는 0777(허벌) 에서 0077을 빼니까 결과적으로 -0700 권한으로 뒤에 있는 파일을 만든다는 이야기. 소유자만 모든 권한을 가지고 있다는 것. 그 뒤에는 'agent_api_key_test' 문자열을 $key_dir 디렉토리 속 secret.key 파일에 저장한다.
fi

printf 'Case=%s MEMORY_LIMIT=%s CPU_MAX_OCCUPY=%s MULTI_THREAD_ENABLE=%s\n' \ 
    "$case_name" "$memory_limit" "$cpu_limit" "$multi_thread" #case_name, memory_limit, cpu_limit, multi_thread 변수의 값을 출력한다. - 위의 테스트 케이스 이름과 조건을 쫙 출력해주는 것이다.
# 이 파트는, 이번 문제 명세서에서 요구하는 환경 변수들을 설정하는 부분이다. AGENT_HOME, AGENT_PORT, AGENT_UPLOAD_DIR, AGENT_KEY_PATH, AGENT_LOG_DIR, MEMORY_LIMIT, CPU_MAX_OCCUPY, MULTI_THREAD_ENABLE 환경 변수를 설정한다. 이 환경 변수들은 agent-leak-app이 실행될 때 사용된다.
export AGENT_HOME="$agent_home"
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="$upload_dir"
export AGENT_KEY_PATH="$key_dir"
export AGENT_LOG_DIR="$log_dir"
export MEMORY_LIMIT="$memory_limit"
export CPU_MAX_OCCUPY="$cpu_limit"
export MULTI_THREAD_ENABLE="$multi_thread"

exec "$app_binary" #마지막으로 exec 명령어를 사용하여 agent-leak-app을 실행한다. exec는 현재 쉘 프로세스를 대체하여 새로운 프로세스를 실행하는 명령어이다. 이로써 스크립트는 종료되고, agent-leak-app이 실행된다. 이 스크립트 실행 뒤에는 monitor.sh를 실행하여 agent-leak-app의 상태를 모니터링할 수 있다.
