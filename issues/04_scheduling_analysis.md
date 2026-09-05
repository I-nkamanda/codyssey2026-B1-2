# [Analysis] 로그 패턴을 통한 스케줄링 알고리즘 추론

## 1. 로그 관찰 개요

안정 설정(`MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=10`, `MULTI_THREAD_ENABLE=false`)에서 Scheduler가 Thread-A, B, C의 작업을 실행하는 순서를 분석했다.

## 2. 증거 자료

```text
Thread-A: 20% → 40% → Preempted
Thread-B: 20% → 40% → Preempted
Thread-C: 20% → 40% → Preempted
Thread-A: 60% → 80% → Preempted
Thread-B: 60% → 80% → Preempted
Thread-C: 60% → 80% → Preempted
Thread-A: 100%
Thread-B: 100%
Thread-C: 100%
```

각 스레드는 첫 구간에서 약 110ms 동안 두 단계(20%씩)를 처리하고 다음 스레드에 차례를 넘겼다.

## 3. 패턴 분석 및 결론

- FCFS가 아니다. A가 완료되기 전에 B와 C가 실행됐다.
- Priority 방식의 증거가 없다. 특정 스레드가 우선하거나 독점하지 않았다.
- A→B→C 순서가 같은 작업량 단위로 반복됐고 로그에 `Preempted`, `Resumed`가 명시됐다.

따라서 애플리케이션 수준 Scheduler는 **Round-Robin**으로 추론한다. 이 결론은 Linux 커널 전체의 스케줄러가 Round-Robin이라는 뜻이 아니라, 관측된 앱의 작업 배분 정책에 대한 결론이다.

## 4. 장단점과 적합한 서비스

| 관점 | 분석 |
| --- | --- |
| 장점 | 작업별 응답 기회를 공평하게 제공하고 starvation을 줄인다. |
| 단점 | time slice가 너무 짧으면 context switching 비용이 커지고, 너무 길면 응답성이 나빠진다. |
| 적합 | 여러 요청을 짧게 번갈아 처리하는 대화형·웹 서비스 |
| 덜 적합 | 순차 처리량이 가장 중요하고 전환 비용이 큰 대형 배치 작업 |
