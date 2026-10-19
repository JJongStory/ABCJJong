# CLAUDE.md — Project HERMES (ABCJJong)

이 저장소에서 작업하는 모든 AI 세션은 아래를 먼저 읽고 따른다.

1. `docs/project/00_PROJECT_BRIEF.md` — 목표(RFP 100점), 워크로드 분해, C1~C10, 공통 규칙
2. `docs/project/01_CONTRACT.md` — 이름·포트·CIDR·API·IAM·모듈 output **고정 규약**
3. `docs/project/02_TASKS.md` — 내가 맡은 Task(T1~T6)의 범위와 완료 기준

규칙 요약
- 계약서의 값을 임의로 바꾸지 말 것. 바꿔야 하면 구현하지 말고 "계약 변경 요청"으로 보고.
- 담당 Task 디렉터리 밖은 수정 금지.
- 평문 크리덴셜 금지 / SG 소스는 SG ID만(외부 ALB 80 예외) / IAM `Resource: "*"` 금지.
- 앱 기능은 최소, `/health`·로그·예외·타임아웃은 확실히. 핵심 설계 이유는 짧은 주석으로.
- 발견한 오류·수정, 프롬프트 개선은 `docs/ai-log.md`에 기록.
- 커밋 메시지: `[T번호] 요약` (예: `[T3] chat-api stub provider`)
