#!/usr/bin/env bash
# 엄격한 bash 스크립트 설정
set -Eeuo pipefail # -e: 스크립트 에러가 나면 즉시 종료 -u: 정의되지 않은 변수를 사용하면 종료 -o pipefail: 파이프라인에서 중간에 오류가 발생하면 전체를 실패로 보고 종료 -E: trap ERR (상속) -e 옵션과 함께 사용하면 ERR 트랩이 상속되어 함수, 서브셸, 파이프라인에서도 ERR 트랩이 실행된다.
export LC_ALL=C # LC locale 설정을 C로 변경하여 숫자, 날짜 등의 형식을 표준화한다. LC_ALL=POSIX와 거의 같은 의미로 쓰인다. C locale은 기본적으로 영어를 사용하며, 숫자와 날짜 형식이 표준화되어 있어 스크립트에서 일관된 동작을 보장한다.
# 인자(args) 처리: interval(샘플링 간격, 초), sample_count(샘플링 횟수), process_pattern(모니터링할 프로세스 패턴), agent_port(에이전트 포트), monitor_log(로그 파일 경로)
interval="${1:-1}" # 샘플링 간격 (초) 형식은 ${변수 순서:-기본값}으로, 인자가 없으면 기본값을 사용한다. 여기서는 첫 번째 인자($1)가 없으면 1초를 기본값으로 사용한다.
sample_count="${2:-1}" # 샘플링 횟수 - 같은 방식으로 두번째 변수이고, 기본값은 1 이런 식.
process_pattern="${AGENT_PROCESS_PATTERN:-agent-leak-app}" # 모니터링할 프로세스 패턴 (기본값 "agent-leak-app")
agent_port="${AGENT_PORT:-15034}" # 에이전트 포트 (기본값 15034)
monitor_log="${MONITOR_LOG_FILE:-./monitor.log}" # 로그 파일 경로 (기본값 "./monitor.log")

[[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '[ERROR] interval must be a non-negative number\n' >&2; exit 2; } #인터벌이 0 이상의 숫자인지 확인한다. 정규식 ^[0-9]+([.][0-9]+)? 는 0 이상의 정수 또는 소수를 의미한다. 만약 조건이 맞지 않으면 에러 메시지를 출력하고 종료코드 2를 내뱉고 종료한다. ([.][0-9]+)?$는 소수점 이하가 있을 수도 있고 없을 수도 있다는 의미이다. '$' 는 문자열의 끝을 의미한다.
[[ "$sample_count" =~ ^[1-9][0-9]*$ ]] || { printf '[ERROR] sample count must be a positive integer\n' >&2; exit 2; } #샘플 카운트가 1 이상의 정수인지 확인한다. 정규식 ^[1-9][0-9]*$는 1 이상의 정수를 의미한다. || 라는 것은 앞의 조건이 false일 경우 뒤의 명령어를 실행한다는 의미이다.  [0-9]*는 0개 이상의 숫자가 반복되는 것을 의미한다.
[[ "$agent_port" =~ ^[0-9]+$ ]] && (( agent_port >= 1 && agent_port <= 65535 )) || { printf '[ERROR] AGENT_PORT must be between 1 and 65535\n' >&2; exit 2; } #포트 번호가 0 이상의 정수이며 동시에 1~65535 사이의 범위에 있는지 확인한다. =~는 정규식 매칭 연산자이고, [0-9]는 '숫자 한 글자' 의미한다. 그러므로 [0-9]+는 1개 이상의 숫자(0과 9 사이)가 반복되는 것을 의미한다.

for required_command in pgrep ps awk df date; do #pgrep, ps, awk, df, date에 대하여 각각: 차례대로 'required_command'라는 변수에 값을 넣고 대입. for구문이다.
    command -v "$required_command" >/dev/null 2>&1 || { printf '[ERROR] required command not found: %s\n' "$required_command" >&2; exit 1; } #linux 중에서 아주 이상한 distro가 아닌 이상은 다 설치되어 있다. command -v [명령어]는 이 명령이 shell에서 실행가능한지, 가능하면 어디에 있는지 확인하는 명령어다. >/dev/null 은 표준출력(stdout)을 버린다(dev/null로 보낸다)는 말이고, 2>&1은 표준에러(stderr)도 1(stdout)과 같은 곳으로 보낸다는 말이다. 즉, 실행가능시에 path를 출력해야 하는데 그 출력을 null로 보낸다(출력하지 않는다는 말). 다만 실패시에는 에러 메시지와 종료 코드는 출력을 해 준다.
done #for 구문 블록의 끝을 표시한다. 말인즉슨 해당 운영체제에 pgrep, ps, awk, df, date 명령어가 설치되어있는지 확인히는 명령어이고, 실패하면 어떤 명령어가 없는지 출력하고 종료 코드 1을 내뱉고 종료한다.

sample_once() { #한번 monitor sample을 찍어보는 함수.
    local timestamp pids worker_pid process_row cpu mem rss_kb rss_mb threads state #local은 함수 내부에서만 쓰는 변수를 선언하는 키워드다.
    local port_state disk_used mem_total_kb mem_available_kb system_mem_used #마찬가지로 계속해서 local 변수를 선언한다.

    timestamp="$(date '+%Y-%m-%d %H:%M:%S')" #타임스탬프 형식을 정해주고
    pids="$(pgrep -f -- "$process_pattern" 2>/dev/null || true)" #pgrep 명령어를 사용하여 process_pattern에 해당하는 프로세스의 PID를 가져온다. -f 옵션은 전체 명령어 라인에서 패턴을 검색하도록 한다. -- 옵션은 뒤에 오는 인자를 옵션으로 인식하지 않게 한다는 의미이다. 
    if [[ -z "$pids" ]]; then # pids가 비어있으면(즉, 해당 프로세스가 실행 중이지 않으면) -z 는 뒤에 오는 "문자열" 길이가 0이면 참을 반환한다는 의미이다.
        printf '[%s] PROCESS:%s STATUS:not-running\n' "$timestamp" "$process_pattern" #[타임스탬프] PROCESS:agent-leak-app STATUS:not-running 와 같이 출력이 된다. 
        return 1 #종료코드 1 출력
    fi

    worker_pid="$({ 
        for process_id in $pids; do ps -p "$process_id" -o pid=,rss= 2>/dev/null || true; done #  각 PID에 대해 ps 명령어를 사용하여 PID와 RSS(Resident Set Size, 실제 메모리 사용량)를 가져온다. -p 옵션은 특정 PID를 지정하고, -o 옵션은 출력 형식을 지정한다. 여기서는 pid=,rss=로 출력 형식을 지정하여 PID와 RSS만 출력하도록 한다. 2>/dev/null은 오류 메시지를 무시하고 버린다. || true는 ps 명령이 실패하더라도 스크립트가 종료되지 않도록 한다.
    } | awk 'NF == 2 && $2 > max { max=$2; pid=$1 } END { print pid }')" #awk를 사용하여 RSS 값이 가장 큰 프로세스의 PID를 선택한다. NF == 2 number of field(항 갯수)가 2개인 것만 읽을 것, $2 > max는 현재 행의 RSS 값($2)이 이전 최대값(max)보다 크면 max를 업데이트하고 pid를 저장한다. END 블록에서 최종적으로 선택된 pid를 출력한다.
    [[ -n "$worker_pid" ]] || return 1 #이 말은 worker_pid가 비어있지 않으면 참을 반환하고, 비어있으면 종료코드 1을 반환한다는 의미이다. -n 은 뒤에 오는 "문자열" 길이가 0이 아니면 참을 반환한다는 의미이다. -z의 반대 개념.

    process_row="$(ps -p "$worker_pid" -o %cpu=,%mem=,rss=,nlwp=,stat= 2>/dev/null | awk '{$1=$1; print}')" #ps 명령어를 사용하여 worker_pid에 대한 CPU 사용률(%CPU), 메모리 사용률(%MEM), RSS, 스레드 수(NLWP), 상태(STAT)를 가져온다. -o 옵션은 출력 형식을 지정하며, = 기호를 사용하여 헤더를 제거한다. awk '{$1=$1; print}'는 각 필드의 공백을 정리하여 출력한다. 2>/dev/null은 오류 메시지를 무시하고 버린다.
    [[ -n "$process_row" ]] || return 1 #process_row가 비어있지 않으면 참을 반환하고, 비어있으면 종료코드 1을 반환한다. 
    read -r cpu mem rss_kb threads state <<<"$process_row" #read 명령어를 사용하여 process_row의 각 필드를 cpu, mem, rss_kb, threads, state 변수에 저장한다. <<<는 here string으로, 문자열을 표준 입력으로 전달하는 방법이다.
    rss_mb="$(awk -v value="$rss_kb" 'BEGIN { printf "%.1f", value / 1024 }')" #rss_kb를 MB 단위로 변환한다. awk를 사용하여 rss_kb 값을 1024로 나누어 MB 단위로 변환하고, 소수점 한 자리까지 출력한다.

    if command -v ss >/dev/null 2>&1 && ss -ltnH 2>/dev/null | awk -v port="$agent_port" '{address=$4; sub(/^.*:/,"",address); if (address==port) found=1} END {exit !found}'; then #ss 명령어가 설치되어 있는지 확인하고, 설치되어 있으면 ss 명령어를 사용하여 agent_port가 LISTEN 상태인지 확인한다. -l 옵션은 LISTEN 상태의 소켓만 표시하고, -t 옵션은 TCP 소켓만 표시하며, -n 옵션은 호스트 이름 대신 숫자 IP 주소를 표시한다. -H 옵션은 헤더를 생략한다. awk를 사용하여 각 행의 네 번째 필드($4)에서 포트 번호를 추출하고, agent_port와 비교하여 일치하면 found 변수를 1로 설정한다. END 블록에서 found 변수가 1이면 exit 0(성공), 그렇지 않으면 exit 1(실패)을 반환한다.
        port_state=LISTEN # ss 명령어가 설치되어 있고, agent_port가 LISTEN 상태이면 port_state를 LISTEN으로 설정한다.
    else
        port_state=closed # ss 명령어가 설치되어 있지 않거나, agent_port가 LISTEN 상태가 아니면 port_state를 closed로 설정한다.
    fi

    disk_used="$(df -P / | awk 'NR == 2 {print $5}')" #df 명령어를 사용하여 루트 디렉토리(/)의 디스크 사용량을 확인한다. -P 옵션은 POSIX 형식으로 출력하도록 한다. awk를 사용하여 두 번째 줄(NR == 2)의 다섯 번째 필드($5)를 출력한다. 이 필드는 디스크 사용량을 백분율로 나타낸다.
    mem_total_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)" #/proc/meminfo 파일에서 MemTotal 값을 읽어와서 mem_total_kb 변수에 저장한다. awk를 사용하여 해당 라인을 찾아서 두 번째 필드($2)를 출력한다. 2>/dev/null은 오류 메시지를 무시하고 버린다. || true는 awk 명령이 실패하더라도 스크립트가 종료되지 않도록 한다.
    mem_available_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)" #/proc/meminfo 파일에서 MemTotal과 MemAvailable 값을 읽어와서 각각 mem_total_kb와 mem_available_kb 변수에 저장한다. awk를 사용하여 해당 라인을 찾아서 두 번째 필드($2)를 출력한다. 2>/dev/null은 오류 메시지를 무시하고 버린다. || true는 awk 명령이 실패하더라도 스크립트가 종료되지 않도록 한다.
    if [[ -n "$mem_total_kb" && -n "$mem_available_kb" ]]; then
        system_mem_used="$(awk -v total="$mem_total_kb" -v available="$mem_available_kb" 'BEGIN {printf "%.1f%%", (total-available)*100/total}')" #사용 메모리를 계산한다. /proc/meminfo 파일에서 MemTotal과 MemAvailable 값을 읽어와서 사용 메모리 비율을 계산한다. awk를 사용하여 계산하며, total과 available 변수를 사용하여 (total-available)*100/total 공식을 적용한다. 결과는 소수점 한 자리까지 출력된다.
    else #아니라면
        system_mem_used=unknown #사용 메모리는 unknown으로 설정한다.
    fi

    printf '[%s] PROCESS:%s PID:%s CPU:%s%% MEM:%s%% RSS:%sMB THREADS:%s STATE:%s PORT:%s:%s DISK_USED:%s SYSTEM_MEM:%s\n' \
        "$timestamp" "$process_pattern" "$worker_pid" "$cpu" "$mem" "$rss_mb" "$threads" "$state" "$agent_port" "$port_state" "$disk_used" "$system_mem_used" #읽어온 모든 변수들을 차례대로 format에 맞게 출력한다. printf는 C언어의 printf와 동일한 기능을 수행한다. \는 줄바꿈을 의미한다.
}

mkdir -p -- "$(dirname -- "$monitor_log")" #로그 파일이 들어갈 디렉토리를 생성. -p 옵션은 상위 디렉토리가 없으면 상위 디렉토리도 생성한다는 의미이다. -- 옵션은 뒤에 오는 인자를 옵션으로 인식하지 않게 한다는 의미이다. $(dirname -- "$monitor_log")는 monitor_log 경로에서 디렉토리 부분만 추출한다.
for ((sample_index = 1; sample_index <= sample_count; sample_index++)); do #C언어 스타일의 for 문 - 샘플 인덱스를 1부터 sample_count까지 반복한다. (( ))는 산술 확장(arithmetic expansion)으로, 내부에서 변수의 값을 계산할 수 있다. ((초기화식;조건식;증감식))
    sample_line="$(sample_once || true)" #sample_once 함수를 호출하고, 실패하면 true를 반환하여 스크립트가 종료되지 않도록 한다. sample_line 변수에 결과를 저장한다.
    printf '%s\n' "$sample_line" | tee -a "$monitor_log" #string 형식으로 sample_line을 출력하고 줄바꿈(\n)을 넣어준다. 동시에 monitor_log 파일에 같은 내용을 append(추가)한다. tee 명령어는 표준출력을 파일로 저장하면서 동시에 화면에도 출력하는 명령어이다. -a 옵션은 append 모드로 파일에 추가한다는 의미이다. 
    (( sample_index < sample_count )) && sleep "$interval" #샘플링 횟수가 아직 남아있으면 interval 초만큼 대기한다. sleep 명령어는 지정한 시간 동안 대기하는 명령어이다. 여기서는 sample_index가 sample_count보다 작은 경우에만 sleep을 실행한다.
done
