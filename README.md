# Project HERMES — 영어 회화 학습 서비스의 하이브리드 실행 환경 (VM · Container · Serverless)

ABC 전문가 과정 Intermediate(Cloud) Final Project — AWS ap-northeast-2

| 워크로드 | 실행 환경 | 소스 | 인프라 |
|---|---|---|---|
| A. content — 학습 콘텐츠 관리 API | VM (EC2 ASG + ALB) | `apps/content-api/` (User Data: `userdata.sh.tftpl`) | `infra/terraform/modules/content` |
| B. chat — 회화 챗봇 API | Container (EKS) | `apps/chat-api/` (Dockerfile), `k8s/` | `infra/terraform/modules/chat`, `.github/workflows/` |
| C. note — 오답노트 저장 | Serverless (API GW + Lambda) | `apps/note-fn/` | `infra/terraform/modules/note` |
| 공통 | 네트워크·데이터·모니터링 | - | `infra/terraform/modules/{network,data,monitoring}` |

- 설계 문서: `docs/project/` · ADR: `docs/ADR.md` · 운영 매트릭스: `docs/ops-matrix.md` · 제약 점검: `docs/constraints-check.md` · AI 협업: `docs/ai-log.md`
- 로컬 실행: `cd local && docker compose up --build` (T5 완료 후)
- 배포 절차: `docs/project/03_CLOUDSHELL_RUNBOOK.md`

> 이 저장소에는 어떤 크리덴셜도 포함하지 않는다. 접속 정보는 AWS Secrets Manager / IAM Role로 주입한다.
