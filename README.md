# Project HERMES — 영어 회화 학습 서비스의 하이브리드 실행 환경 (VM · Container · Serverless)

ABC 전문가 과정 Intermediate(Cloud) Final Project — AWS ap-northeast-2

| 워크로드 | 실행 환경 | 소스 | 인프라 |
|---|---|---|---|
| A. content — 학습 콘텐츠 관리 API | VM (EC2 ASG + ALB) | `apps/content-api/` (User Data: `userdata.sh.tftpl`) | `infra/terraform/modules/content` |
| B. chat — 회화 챗봇 API | Container (EKS) | `apps/chat-api/` (Dockerfile), `k8s/` | `infra/terraform/modules/chat`, `.github/workflows/` |
| C. note — 오답노트 저장 | Serverless (API GW + Lambda) | `apps/note-fn/` | `infra/terraform/modules/note` |
| 공통 | 네트워크·데이터·모니터링 | - | `infra/terraform/modules/{network,data,monitoring}` |

- 설계 문서: `docs/project/` · ADR: `docs/ADR.md` · 운영 매트릭스: `docs/ops-matrix.md` · 제약 점검: `docs/constraints-check.md` · AI 협업: `docs/ai-log.md`
- 로컬 실행: 아래 "로컬 실행" · 배포 절차: 아래 "배포 순서" · 측정: 아래 "운영 측정"

## 로컬 실행
```bash
cd local && docker compose up --build        # mysql / content-api / chat-api(stub) / dynamodb-local
curl -s localhost:8080/ | python3 -m json.tool          # content-api: hostname + sample
curl -s localhost:8000/scenario | python3 -m json.tool  # chat-api → content-api (C4 로컬 리허설)
```
k3d 리허설: `k3d cluster create --config local/k3d-cluster.yaml` 후 `k8s/` 매니페스트 적용(Ingress 제외). 앱별 테스트는 각 `apps/*/tests/`를 `pytest`로 실행한다.
(위 파일은 다른 Task 산출물이며, 없는 경우 해당 Task 완료 후 사용)

## 학습자 화면 (`/ui`)
chat-api가 정적 페이지 `apps/chat-api/static/index.html`을 `GET /ui`로 제공한다. Ingress ALB 주소 뒤에 `/ui`를 붙여 접속한다.

- 닉네임 로그인(2~20자, 영문·숫자·한글·`_`·`-`) — 닉네임이 DynamoDB `user_id`가 된다
- 탭 3개: **시나리오**(VM 콘텐츠 API → RDS) · **대화 기록**(대화 저장/조회) · **오답노트**(Serverless → DynamoDB)
- 대화 응답에 영어 교정문과 한글 발음(transliteration)을 함께 표시하고, 화면 하단 trace 패널에 각 호출이 거친 실행 환경을 보여준다
- chat-api가 note API를 대신 호출(`/notes/{user_id}`, `/conversations`, `/note`)하므로 브라우저는 Ingress ALB 하나만 알면 된다
- DynamoDB SK 규칙: 오답노트 = `created_at`(ISO 시각), 대화 = `conv#<created_at>`

## 배포 순서 (AWS CloudShell, ap-northeast-2)
상세 명령은 `docs/project/03_CLOUDSHELL_RUNBOOK.md`. 의존 순서: **network → data → chat(EKS) → content → note → monitoring**

| 단계 | 내용 | 비고 |
|---|---|---|
| 0 | `source scripts/bootstrap.sh`, state 버킷 생성, `terraform init -backend-config=…` | 세션마다 bootstrap 재실행 |
| 1 | `terraform apply -target=module.network -target=module.data` | RDS Multi-AZ 포함 |
| 2 | `terraform apply -target=module.chat` | EKS 15~20분, 탭 유지 |
| 3 | `terraform apply -target=module.content` → 외부 ALB `/` 확인 | VM 최초 배포 |
| 4 | LB Controller(helm) → 이미지(GitHub Actions 또는 CloudShell 빌드) → `render-k8s.sh \| kubectl apply` | Ingress ALB 2~3분 |
| 5 | `terraform apply -target=module.note` → `POST /notes` | |
| 6 | `terraform apply -target=module.monitoring` | 이메일 구독 확인 링크 클릭(수동) |

CI: `.github/workflows/chat-api.yml` — main push(`apps/chat-api/**`) 시 OIDC로 AssumeRole → ECR push(태그 = short SHA) → `kubectl set image` → rollout status.
저장소 **Variables**(Settings → Secrets and variables → Actions → Variables)에 `AWS_ROLE_ARN`, `AWS_REGION`, `ECR_REPOSITORY`, `EKS_CLUSTER_NAME` 을 등록한다(계정 ID·ARN을 코드에 두지 않는다).

## 운영 측정
모든 운영 작업은 `scripts/ops/measure.sh` 로 감싸 소요시간을 `docs/ops-matrix.csv` 에 자동 기록한다.
```bash
scripts/ops/watch_availability.sh "http://<url>/" 1 &        # 무중단 여부: 200/비200 타임라인 csv
scripts/ops/measure.sh vm recover -- bash -c 'aws ec2 terminate-instances --instance-ids <id> >/dev/null && scripts/ops/wait_http.sh "http://<alb>/" hostname'
kill %1                                                       # 요약(총 횟수, 비200, 최장 연속 실패) 출력
```
- `wait_http.sh URL [기대문자열] [timeout=600]`: 1초 폴링, 성공 시 `OK <초>s (failures=N)`.
- 측정 정의와 3×4 표: `docs/ops-matrix.md` · 제약 점검: `docs/constraints-check.md` · 비용: `docs/cost.md` · 결정 기록: `docs/ADR.md`

> 이 저장소에는 어떤 크리덴셜도 포함하지 않는다. 접속 정보는 AWS Secrets Manager / IAM Role로 주입한다.
