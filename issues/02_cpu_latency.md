# [Bug] CPU 내부 관제값 상승 후 보호 정책에 의한 SIGTERM 종료

## 1. Description (현상 설명)

`MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=100`, `MULTI_THREAD_ENABLE=false`로 실행하면 메모리 증가 없이 CPU 부하가 단계적으로 상승했다. 내부 관제값 52.88%에서 임계치 위반이 기록된 직후 프로세스가 약 24초 만에 SIGTERM으로 종료됐다.

## 2. Evidence & Logs (증거 자료)

```text
01:22:33 [CpuWorker] Current Load: 5.00%
01:22:36 [CpuWorker] Current Load: 13.10%
01:22:39 [CpuWorker] Current Load: 22.66%
01:22:42 [CpuWorker] Current Load: 31.38%
01:22:45 [CpuWorker] Current Load: 36.93%
01:22:48 [CpuWorker] Current Load: 41.79%
01:22:51 [CpuWorker] Current Load: 47.05%
01:22:55 [CpuWorker] Current Load: 52.88%
01:22:55 [CRITICAL] [CpuWorker] CPU Threshold Violated! (52.879999999999995%).
launcher_exit=143 elapsed_seconds=24
```

종료 코드 143은 `128 + 15`로 SIGTERM과 일치한다. 외부 `ps`의 1초 샘플은 워커의 실행 이후 평균을 0.3~1.0%로 표시하여 짧은 내부 부하 변화를 그대로 반영하지 못했다. 따라서 본 판정은 앱 내부의 연속 관제값, 임계치 로그, 종료 신호를 결합한 것이다.

```text
01:22:42 PID 2641 CPU 0.5% MEM 0.1% RSS 17208KB STAT SN
01:22:51 PID 2641 CPU 0.8% MEM 0.1% RSS 17208KB STAT SN
01:22:53 PID 2641 CPU 1.0% MEM 0.1% RSS 17208KB STAT SN
```

| 지표 | Before: 100% | After: 10% |
| --- | --- | --- |
| 내부 부하 | 5.00→52.88% | 5.00~10.00% 반복 |
| 보호 동작 | `CPU Threshold Violated` 후 SIGTERM | 10%에서 cooldown |
| 관찰 시간 | 약 24초에 자체 종료 | 90초 생존 후 시험자가 종료 |
| 메모리 동작 | 17MB 부근으로 유지 | 512MB 도달 시 캐시 정리 후 회복 |

After 실행에서는 `Peak reached (10.00%). Starting cooldown...`과 `Cooldown complete (5.00%). Resuming load increase...`가 반복됐다.

## 3. Root Cause Analysis (원인 분석)

CPU_MAX_OCCUPY가 100%이면 CpuWorker가 부하를 계속 높였고, 내부 보호 기준인 약 50%를 넘었다. Watchdog 성격의 보호 정책은 호스트 전체 지연을 막기 위해 정상 오류 반환을 기다리지 않고 SIGTERM으로 프로세스를 종료했다. 이는 크래시 신호가 아니라 명시적 보호 동작으로 해석된다.

특정 프로세스가 CPU 시간을 과도하게 쓰면 같은 실행 큐의 다른 프로세스와 스레드가 더 오래 대기하여 응답 지연이 발생한다. 다만 이 VM에서 외부 `ps` 평균값과 앱 내부 관제값 사이에 차이가 있었으므로 운영 진단에서는 `pidstat -p <pid> 1`, `top -H`, cgroup CPU 통계도 함께 수집해야 한다.

## 4. Workaround & Verification (조치 및 검증)

- 임시 조치: `CPU_MAX_OCCUPY=100`을 `10`으로 낮췄다.
- 결과: 부하는 10%에서 냉각되어 90초의 관찰 시간 동안 Watchdog 종료가 없었다.
- 근본 조치: busy loop 제거, 작업 단위 분할, blocking I/O 사용, back-pressure/rate limit 적용, cgroup CPU quota 설정을 검토한다.
- 완료 조건: 실제 운영 부하 시험에서 프로세스별 CPU, run queue, p95/p99 latency를 동시에 비교하고 Watchdog 종료가 재발하지 않아야 한다.
