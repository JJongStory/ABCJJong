# 04. AI 협업 기록 (요구사항 8 — 발표 14장 원천)

> 작업하면서 즉시 기록. 4개 항목 모두 최소 1건 필요. 형식만 맞추면 발표 14장으로 바로 옮길 수 있다.

## ① 설계 단계 — 아키텍처 대안 비교 (≥2안)
| # | 일시 | 모델 | 질문 요지 | 대안 A | 대안 B | (대안 C) | 채택 | 기각 사유 |
|---|---|---|---|---|---|---|---|---|
| 1 | 10/12 | Opus | 영어 회화 서비스를 실행 환경에 어떻게 배치할까 (장점·단점·2.5일 구축 가능 여부로 비교) | EKS 하나 + RDS 이중화 (초기안) | 기능 분해 VM(콘텐츠) + EKS(챗봇) + Lambda(기록) | VM + ECS Fargate + Lambda | B | A: 상태·변경 주기·트래픽이 다른 기능을 한 방식으로 운영하게 됨. C: 운영은 가장 가벼우나 AWS 전용이라 이식성·표준 생태계(Helm, HPA, 매니페스트) 측면에서 B를 우선 |
| 2 | 10/12 | Opus | 챗봇 LLM 모델 선택 | Claude 3.5 Haiku | Claude Haiku 4.5 | - | B | 서울 리전 Global 추론 프로파일 목록에 3.5 Haiku가 없음 |

## ② 검토 단계 — 완성 설계를 AI에 검토시킨 지적사항과 대응
| # | 일시 | 지적사항 | 대응 (수용/기각) | 사유 |
|---|---|---|---|---|
| 1 | 10/12 | Lambda를 VPC 밖에 두면 C1 "모든 워크로드가 하나의 VPC" 위반 소지 | 수용 | Lambda VPC 연결 + DynamoDB Gateway Endpoint |
| 2 | 10/12 | Pod → 외부 ALB 호출 시 NAT 경유로 IP 기반 허용 불가피(C8 위반) | 수용 | 내부 ALB 추가, SG-to-SG |
| 3 | 10/12 | 서울 리전 Global CRIS 목록에 Claude 3.5 Haiku 없음 | 수용 | Haiku 4.5로 변경 + stub 폴백 |
| 4 | 10/20 | (T6) main 머지 시 `apps/chat-api/**` 변경으로 CI 가 돌지만 Variables·AWS Role 이 없어 main 이 red | 수용 | job `if: vars.AWS_ROLE_ARN != ''` 가드 |
| 5 | 10/20 | (T6) content-api 503 응답에 내부 예외 원문(RDS 호스트명·IP)이 외부 ALB 로 노출 | 수용 | 응답은 `database unavailable`, 원인은 로그로 |
| 6 | 10/20 | (T6) LT 의 AMI 를 SSM 최신값으로 매 plan 조회 → 3일 중 AMI 갱신 시 의도치 않은 instance refresh | 수용 | `ignore_changes = [image_id]` |
| 7 | 10/20 | (T6) 계정에 GitHub OIDC provider 가 이미 있으면 생성 충돌, 모듈 변수는 있으나 루트에 미노출 | 수용 | 루트 `github_oidc_provider_arn` 변수 추가 |
| 8 | 10/20 | (T6) runbook 의 `render-k8s.sh \| kubectl apply` 에 필수 env(IMAGE·IRSA ARN·CONTENT_API_URL) 누락 → 실패 | 수용 | runbook 에 export 5줄(내부 ALB DNS 앞 `http://` 포함) |
| 9 | 10/20 | (T6) `bootstrap.sh` 를 source 하면 `set -u` 가 대화형 셸에 남음 | 수용 | 옵션 제거 |
| 10 | 10/20 | (T6) constraints-check C8 이 "80/443 예외"로 계약서(80만)와 불일치 | 수용 | 80 으로 정정 (00_BRIEF 4장 문구는 기획 단계에서 정정 필요) |
| 11 | 10/20 | (T6) ASG health grace 120s 가 User Data(dnf+pip) 완료보다 짧을 수 있음 → 교체 루프 위험 | 수용 | Day 1 실측(부팅~200 약 2분 이상) 후 계약 변경, grace 300s |
| 12 | 10/20 | (T6) EKS 노드 SG 별도 생성 시 Pod 소스가 cluster SG 가 아니게 되어 C4 실패 가능 | 기각 | 노드그룹이 launch template 없이 cluster SG 를 그대로 사용(`modules/chat/eks.tf`) — 문제 없음 |
| 13 | 10/20 | (T6) Global 추론 프로파일은 다른 리전 foundation-model ARN 권한도 필요 | 기각 | 이미 `bedrock:*::foundation-model/...` 로 작성됨(`modules/chat/iam.tf`) |
| 14 | 10/20 | (T6) ALBC 정책·ECR GetAuthorizationToken 의 `Resource "*"` | 기각(예외 인정) | API 가 리소스 수준 권한 미지원 / upstream 공식 정책. 사유 주석 존재 |
| 15 | 10/20 | (T6) chat `/note` 프록시가 SigV4 없이 호출 | 기각 | note HTTP API 는 IAM authorizer 미사용(C3 공개 엔드포인트) — 계약 9장 `execute-api:Invoke` 는 선택 |
| 16 | 10/20 | 실습 계정이 공유 계정(user17)으로 배정 → 이름 충돌·계정 전역 자원(GitHub OIDC) 삭제 위험 | 수용 | 접두사 user17-hermes, CI Role 비활성, CloudShell 빌드 |

## ③ 구현 단계 — AI 생성 코드의 오류/보안 취약점과 수정 (≥1건)
| # | 일시 | 파일 | 생성 모델 | 발견한 문제 | 위험 | 수정 내용 | 발견 주체 |
|---|---|---|---|---|---|---|---|
| 1 | 10/19 | `apps/chat-api/llm.py` | Sonnet 5.5 (세션 A) | botocore `max_attempts=1` 은 "재시도 1회(총 2회)" → Bedrock 최악 20s | /chat 이 계약 타임아웃 10s 초과 | `retries={"total_max_attempts": 1}` | 세션 A 자체 (코드 주석 근거) |
| 2 | 10/19 | `apps/note-fn/handler.py` | Sonnet 5.5 (세션 A) | SK `created_at` 초 단위면 같은 사용자 동시 저장 시 덮어쓰기 | 오답노트 유실 | 마이크로초 ISO8601 + `attribute_not_exists` 조건 | 세션 A 자체 |
| 3 | 10/19 | `local/docker-compose.yml` | Sonnet 5.5 (세션 A) | DDB Local 용 키를 `${AWS_...}` 보간하면 호스트 실제 자격증명이 컨테이너로 유입 | 크리덴셜 유출 | 고정 더미 값 사용 | 세션 A 자체 |
| 4 | 10/19 | `infra/terraform/modules/data/outputs.tf` | Sonnet 5.5 (세션 B) | `aws_db_instance.endpoint` 는 `host:3306` | 앱 DB_HOST 깨짐 | `.address` 출력 (앱도 `host:port` 허용) | 세션 B 자체 |
| 5 | 10/19 | `infra/terraform/modules/monitoring/main.tf` | Sonnet 5.5 (세션 B 서브에이전트) | SNS 를 `alias/aws/sns` 로 암호화 | CloudWatch 알람이 Publish 불가 → 알림 증적(가점) 0 | KMS 설정 제거, SECURITY_SCAN.md 에 수용 사유 | 세션 B 자체 |
| 6 | 10/19 | `infra/terraform/modules/data/main.tf` | Sonnet 5.5 (세션 B) | DDB 리소스 정책을 `dynamodb:*` Deny 로 쓰면 제어 평면까지 막힘 | terraform 이 자기 테이블에 잠김 | 데이터 평면 8개 액션만 Deny | 세션 B 자체 |
| 7 | 10/19 | `infra/terraform/modules/content/main.tf` | Sonnet 5.5 (세션 B) | RDS 3306 규칙을 data 모듈에 두면 `-target=module.data` 가 EKS 까지 끌고 옴 | Day 1 단계 apply 실패/지연 | 규칙을 content 모듈의 별도 rule 리소스로 | 세션 B 자체 |
| 8 | 10/20 | `.github/workflows/chat-api.yml` | Sonnet 5.5 (세션 C) | Variables 미등록 상태에서도 main push 시 실행 | PR 머지 직후 main red | job `if:` 가드 | Opus 5.5 T6 리뷰 |
| 9 | 10/20 | `apps/content-api/app.py` | Sonnet 5.5 (세션 A) | 503 detail 에 예외 원문 포함 | 외부(인터넷)로 RDS 호스트명·내부 IP 노출 | 일반 문구 + 로그 | Opus 5.5 T6 리뷰 (통합 시나리오 DB down 테스트에서 확인) |
| 10 | 10/20 | `infra/terraform/modules/content/main.tf` | Sonnet 5.5 (세션 B) | AMI 를 SSM 최신값으로 매번 해석 | AMI 갱신 시 apply 마다 instance refresh → ② 측정 왜곡 | `ignore_changes = [image_id]` | Opus 5.5 T6 리뷰 |
| 11 | 10/20 | `infra/terraform/main.tf` | Sonnet 5.5 (세션 B) | 모듈의 `github_oidc_provider_arn` 를 루트에서 못 넘김 | 기존 provider 있는 계정에서 EntityAlreadyExists | 루트 변수·tfvars 항목 추가 | Opus 5.5 T6 리뷰 |
| 12 | 10/20 | `docs/project/03_CLOUDSHELL_RUNBOOK.md` | Opus 5.5 (T0) | render-k8s 필수 env 누락, CONTENT_API_URL 연결 방법 미기재 | Day 2 컨테이너 배포 실패 / C4 미연결 | export 5줄 추가 | Opus 5.5 T6 리뷰 |
| 13 | 10/20 | `scripts/bootstrap.sh` | Opus 5.5 (T0) | source 스크립트에 `set -u` | CloudShell 대화형 셸 오동작 | 제거 | Opus 5.5 T6 리뷰 |
| 14 | 10/20 | `apps/chat-api/llm.py` | Opus 5.5 | 시스템 프롬프트에 발음 표기 규칙이 없어 LLM이 발음 칸에 한국어 원문을 그대로 넣음 | 학습자 화면의 핵심 기능(한글 발음) 미동작 | 규칙과 예시를 프롬프트에 추가, `maxTokens` 600 | 사용자(본인) — 배포 후 화면 테스트에서 발견, E23에서 수정 확인 |

> 세션 A·B·C의 최종 보고 원문은 T6에 전달되지 않아, 1~7은 커밋된 코드 주석·`SECURITY_SCAN.md`를 근거로 기록했다. 보고 원문을 받으면 보완한다.

## ④ 프롬프트 Before / After (≥1건)
### Before
```
세션 A~C: 작업 후 dev/apps, dev/infra, dev/ops 브랜치를 만들어 push하라.
세션 D: dev/* 브랜치를 merge해 통합하라.
```
결과 문제: 클라우드 Claude Code 세션은 세션마다 지정된 `claude/*` 브랜치에만 push할 수 있어 dev/* 브랜치가 생성되지 않았고, 통합 세션(D)이 "브랜치 없음"으로 작업을 진행하지 못함. 또 PR #2는 PR #1 머지 전 main을 기준으로 실행되어 닫고 다시 수행.

### After
```
세션에 지정된 브랜치를 그대로 쓰고 다른 브랜치를 만들지 마라.
push 후 `git ls-remote origin <브랜치>`로 원격 반영을 확인하라.
보고 첫 줄에 브랜치 이름과 마지막 커밋 SHA를 적어라.
(통합 세션) 선행 PR이 main에 머지된 것을 확인한 뒤 시작하라.
```
개선 포인트: 실행 환경의 제약(push 가능 브랜치)을 명시하고, 스스로 결과를 검증하게 하며, 다음 단계로 넘길 정보(브랜치·SHA)를 고정. 선후 관계(머지 완료)를 시작 조건으로 둠.
