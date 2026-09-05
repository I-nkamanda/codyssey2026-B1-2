# [Bug] MemoryGuard 임계치 도달 후 agent-leak-app 자체 종료

## 1. Description (현상 설명)

Ubuntu 22.04 ARM64 VM에서 `MEMORY_LIMIT=50`으로 실행하면 `Agent READY` 이후 약 6초 만에 프로세스가 종료됐다. 동일 조건에서 제한만 100MB로 올리면 약 12초 동안 생존했다. 두 실행 모두 종료 직전까지 Heap과 RSS가 단계적으로 증가했다.

## 2. Evidence & Logs (증거 자료)

```text
[2026-09-06 01:31:11] PROCESS:agent-leak-app PID:2970 CPU:1.0% MEM:0.1%
RSS:16.8MB THREADS:1 STATE:SN PORT:15034:LISTEN DISK_USED:1% SYSTEM_MEM:4.4%
[2026-09-06 01:31:13] PROCESS:agent-leak-app PID:2970 CPU:0.6% MEM:0.3%
RSS:41.8MB THREADS:1 STATE:SN PORT:15034:LISTEN DISK_USED:1% SYSTEM_MEM:4.6%

01:19:18 [INFO] [MemoryWorker] Current Heap: 25MB
01:19:21 [INFO] [MemoryWorker] Current Heap: 50MB
01:19:21 [CRITICAL] [MemoryGuard] Memory limit exceeded (50MB >= 50MB)
01:19:21 [CRITICAL] [MemoryGuard] Self-terminating process 1867 to prevent system instability.
launcher_exit=137
```

종료 코드 137은 `128 + 9`로, SIGKILL 종료와 일치한다.

| 지표 | Before 50MB | After 100MB |
| --- | ---: | ---: |
| 관측 Heap 단계 | 25, 50MB | 25, 50, 75, 100MB |
| 종료까지 시간 | 약 6초 | 약 12초 |
| 종료 로그 | 50 >= 50 | 100 >= 100 |
| 종료 코드 | 137 | 137 |

## 3. Root Cause Analysis (원인 분석)

Heap 데이터가 주기적으로 25MB씩 누적되고 회수되지 않았다. 외부 RSS 증가와 내부 Heap 증가가 같은 방향으로 움직이므로 메모리 누수 또는 의도적인 미해제 할당으로 판단한다. 임계치에 도달하자 Linux OOM Killer가 개입한 것이 아니라 애플리케이션 내부 MemoryGuard가 PID 1867에 SIGKILL을 보내 시스템 불안정을 예방했다. 제한을 높이면 종료 시점만 늦어지고 같은 증가 패턴과 종료가 반복되므로 근본 원인은 남아 있다.

## 4. Workaround & Verification (조치 및 검증)

- 임시 조치: `MEMORY_LIMIT`을 50MB에서 100MB로 상향했다.
- 결과: 생존 시간이 약 6초에서 12초로 늘어 긴급 작업을 마칠 시간을 확보했다.
- 한계: 100MB에서도 동일하게 종료됐으므로 장애 해결이 아니라 완화다.
- 근본 조치: 장기 보유 객체의 참조 관계를 추적하고, 캐시 상한/TTL을 설정하며, 작업 완료 후 컨테이너·버퍼·파일 핸들을 명시적으로 해제한다. 배포 전 heap profiler와 장시간 soak test로 RSS가 정상 범위로 회귀하는지 확인한다.
