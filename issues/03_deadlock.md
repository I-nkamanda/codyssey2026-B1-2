# [Bug] 멀티스레드 락 순서 역전으로 프로세스 무응답

## 1. Description (현상 설명)

`MULTI_THREAD_ENABLE=true`로 실행하면 PID와 TCP 리스너는 유지되지만, 두 워커가 BLOCKED 로그를 남긴 뒤 추가 작업 로그가 멈췄다. 25초 동안 프로세스는 종료되지 않았고 CPU/메모리 변화도 정체됐다.

## 2. Evidence & Logs (증거 자료)

```text
jingeollee 2836 ... /tmp/b1-2-agent/agent-leak-app
jingeollee 2846 ... /tmp/b1-2-agent/agent-leak-app

PID  LWP   CPU  MEM  STAT WCHAN
2846 2846  0.0  0.1  SNl  futex_
2846 2874  0.0  0.1  SNl  futex_
2846 2875  0.0  0.1  SNl  futex_

[Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
[Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
[Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
[Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
[Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
[Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
```

동일한 스레드 상태가 여러 샘플에서 반복되었다. PID가 존재하고 세 스레드가 모두 0.0% CPU, `futex` 대기 상태였으므로 단순 종료나 고부하 상태가 아니다.

## 3. Root Cause Analysis (원인 분석)

```text
Thread-1: A 보유 ──기다림──> B
Thread-2: B 보유 ──기다림──> A
```

- 상호 배제: A와 B는 한 스레드만 보유할 수 있다.
- 점유 대기: 각 스레드는 하나를 보유한 채 다른 하나를 기다린다.
- 비선점: 상대가 보유한 락을 강제로 빼앗을 수 없다.
- 순환 대기: Thread-1 → B/Thread-2 → A/Thread-1의 원이 만들어진다.

교착상태의 네 필요조건이 모두 성립한다. `futex` 대기는 mutex 경합으로 스레드가 커널 대기 상태에 들어갔다는 외부 증거이고, 마지막 로그는 어떤 락 관계에서 순환이 생겼는지 보여주는 내부 증거다.

## 4. Workaround & Verification (조치 및 검증)

`MULTI_THREAD_ENABLE=false`로 바꾸자 A→B→C가 각각 40%까지 실행되고, 같은 순서로 80%, 100%까지 진행된 뒤 `[Scheduler] All tasks completed.`가 출력됐다.

- 임시 조치: 동시 실행을 끄고 단일 실행 경로로 우회한다.
- 근본 조치: 모든 코드에서 A→B처럼 전역 락 순서를 강제한다. 가능한 경우 중첩 락을 제거하고, `acquire(timeout=...)` 실패 시 이미 가진 락을 해제한 뒤 재시도한다.
- 검증: 멀티스레드 재활성화 후 장시간 반복 시험에서 `futex` 대기가 지속되지 않고 모든 transaction completion 로그가 남아야 한다.
