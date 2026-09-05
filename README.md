# B1-2. 리눅스 프로세스 및 시스템 리소스 트러블슈팅

제공된 `agent-leak-app`을 격리된 Ubuntu 22.04 ARM64 VM에서 직접 실행하여 OOM Crash, CPU Latency, Deadlock을 재현하고 분석한 결과물이다. 수치는 2026-09-06 실측값이며, 예시 데이터와 구분하였다.

## 제출 산출물

| 구분 | 문서 | 핵심 결과 |
| --- | --- | --- |
| 통합 수행내역서 | [B1-2_수행내역서.md](B1-2_수행내역서.md) | 환경, 재현 절차, 세 장애 결론, 검증표 |
| OOM Issue | [issues/01_oom_crash.md](issues/01_oom_crash.md) | 50MB/100MB 제한 전후 비교 |
| CPU Issue | [issues/02_cpu_latency.md](issues/02_cpu_latency.md) | 100%/10% 설정 전후 비교 |
| Deadlock Issue | [issues/03_deadlock.md](issues/03_deadlock.md) | 멀티스레드 활성/비활성 비교 |
| 보너스 분석 | [issues/04_scheduling_analysis.md](issues/04_scheduling_analysis.md) | Round-Robin 추론 |
| 실행 테스트 기록 | [실행_테스트_기록.md](실행_테스트_기록.md) | 실제 명령, 출력, 단계별 해설 |
| 발표 시연 가이드 | [발표_시연_가이드.md](발표_시연_가이드.md) | 두 터미널로 세 장애를 재현하는 발표 순서 |
| 초보자 학습 자료 | [초보자를_위한_B1-2_학습자료.md](초보자를_위한_B1-2_학습자료.md) | 비전공자가 문제와 결과물을 단계별로 이해하는 교재 |
| 학습 후기 | [학습_후기.md](학습_후기.md) | 관제와 장애 분석에서 배운 점 |

## 실행 도구

- `run-case.sh`: 아키텍처를 자동 선택하고 사례별 환경변수를 구성한다.
- `monitor.sh`: 대상 프로세스의 CPU, 메모리, RSS, 스레드, 상태, 포트와 시스템 리소스를 기록한다.

```bash
# VM 안에서 실행
./run-case.sh oom-before

# 다른 터미널에서 1초 간격으로 10회 관제
./monitor.sh 1 10
```

지원 사례는 `oom-before`, `oom-after`, `cpu-before`, `cpu-after`, `deadlock-before`, `deadlock-after`이다. Deadlock 사례처럼 종료되지 않는 실행은 관찰 후 `Ctrl+C`로 종료한다.

## 검증 환경

- Ubuntu 22.04, Linux `aarch64` (OrbStack VM)
- 일반 사용자 `jingeollee` (uid 501)
- ARM64 바이너리 `agent-leak-app-arm64`
- 애플리케이션 포트 TCP 15034

> 제공 바이너리는 디컴파일하거나 리버스 엔지니어링하지 않았다. 보고서의 원인 분석은 관제 출력과 애플리케이션 로그만을 근거로 한다.
