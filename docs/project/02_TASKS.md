# 02. TASKS — 사전 개발(10/15~10/19) 병렬 작업 지시서

## 운영 방식
| 단계 | 모델 | 내용 |
|---|---|---|
| T0 기획 | Opus 5.5 (Medium) | `00`, `01` 확정·수정. 각 Task 결과 통합 판단 |
| T1~T5 구현 | Sonnet 5.5 (Medium) | **병렬**. 각자 담당 디렉터리만 수정 |
| T6 리뷰 | Opus 5.5 (Medium) | C1~C10·요구사항 기준 교차 검토 → 지적사항을 `docs/ai-log.md`에 기록 (요구사항 8 증적) |

공통 규칙 (모든 Task 프롬프트 맨 앞에 붙인다):
```
너는 Project HERMES의 구현 담당이다. 반드시 00_PROJECT_BRIEF.md와 01_CONTRACT.md를 먼저 읽고,
계약서의 이름·포트·CIDR·API 스키마를 그대로 사용하라. 계약서와 다르게 해야 할 이유가 있으면 구현하지 말고 "계약 변경 요청"으로 보고하라.
- 평문 크리덴셜 금지, SG 소스는 SG ID만(외부 ALB 80 예외), IAM Resource "*" 금지
- 앱 기능은 최소, 대신 /health·로그·예외 처리·타임아웃은 확실히
- 발표에서 내가 설명해야 하므로 핵심 설계 이유를 주석으로 짧게 남겨라
- 담당 디렉터리 밖 파일은 수정하지 마라
- 마지막에 (1) 생성 파일 목록 (2) 로컬 검증 명령과 기대 결과 (3) 남은 가정/리스크를 보고하라
```

---

## T1. 네트워크·데이터·공통 IaC  (`infra/terraform/` 루트, `modules/network`, `modules/data`, `modules/monitoring`)
```
[공통 규칙]
목표: 01_CONTRACT 2·3·4·8·11장대로 Terraform을 작성한다.
- 루트: backend.tf(S3 backend, use_lockfile=true, bucket/key는 -backend-config로 주입), providers.tf(default_tags), variables.tf, main.tf, outputs.tf
- modules/network: VPC, 6개 서브넷(태그 포함), IGW, NAT 1개, 라우트테이블 3종, S3/DynamoDB Gateway Endpoint
- modules/data: RDS MySQL Multi-AZ(manage_master_user_password), 서브넷그룹, rds-sg(인바운드는 변수로 받은 content-ec2-sg ID만),
  DynamoDB 테이블(+ aws:SourceVpce 또는 관리자 Role만 허용하는 리소스 정책, 관리자 Role ARN은 변수),
  artifacts S3 버킷(퍼블릭 차단, 버전관리, SSE), random suffix
- modules/monitoring: SNS 토픽 + 이메일 구독(변수), 알람 3개(content 외부 ALB 5XX>=1/1분, content ASG CPU>70%, note Lambda Errors>=1)
- SG 간 순환참조는 aws_vpc_security_group_ingress_rule 별도 리소스로 해결
완료 기준: terraform fmt / validate 통과, tflint 경고 0(가능하면), 모듈 outputs 이름이 계약서 11장과 일치
```

## T2. 워크로드 A — content (VM)  (`apps/content-api/`, `infra/terraform/modules/content`)
```
[공통 규칙]
목표: 01_CONTRACT 5장의 content-api와 배포 인프라를 만든다.
- app.py: FastAPI. /health, /, /scenarios, /scenarios/{id}. 기동 시 테이블 생성+seed(멱등).
  DB 접속정보는 env DB_SECRET_ARN이 있으면 boto3로 Secrets Manager 조회, 없으면 로컬용 env(DB_USER/DB_PASSWORD) 사용.
  AZ는 IMDSv2(토큰) 조회, 실패 시 "local".
- userdata.sh.tftpl: AL2023에서 python3-pip 설치 → S3 zip 다운로드 → venv → systemd 등록·enable·start. set -euo pipefail, 로그는 /var/log/content-userdata.log.
  재부팅/재생성 시 동일 상태로 기동(멱등). 사람 접속 없이 완료.
- content-api.service: Restart=always
- modules/content: Launch Template(IMDSv2 required, 인스턴스 프로파일), ASG(min1/max2, ELB health, instance_refresh 블록),
  외부 ALB+TG, 내부 ALB+TG, SG 3종(계약서 3장), 인스턴스 역할 정책(시크릿·S3 ARN 한정), aws_s3_object로 zip 업로드(archive_file)
- tests/: pytest로 /, /health 응답 스키마 검증 (DB는 docker mysql)
완료 기준: local/docker-compose의 mysql + content-api로 `curl localhost:8080/` 가 hostname·sample 반환, terraform validate 통과
```

## T3. 워크로드 B — chat (Container)  (`apps/chat-api/`, `k8s/`, `infra/terraform/modules/chat`, `.github/workflows/`)
```
[공통 규칙]
목표: 01_CONTRACT 6장의 chat-api 컨테이너와 EKS 배포 일체를 만든다.
- app.py: /health, /, /scenario(CONTENT_API_URL 호출, timeout 3s, 실패 시 502와 원인), /chat, (선택)/note
- llm.py: Provider 인터페이스 + BedrockProvider(boto3 bedrock-runtime Converse, 시스템 프롬프트로 JSON 7필드 강제) +
  GeminiProvider(키는 Secrets Manager) + StubProvider(고정 응답). 예외/10s 타임아웃 시 Stub 폴백.
- Dockerfile: python:3.12-slim, non-root 유저, 멀티스테이지 불필요, HEALTHCHECK 없음(K8s probe 사용), 포트 8000
- k8s/*.yaml: 계약서 6장대로(namespace, SA+IRSA annotation 자리표시자, configmap, deployment replicas 2·probe·topologySpread, service, ingress alb, hpa)
  이미지·IRSA ARN·내부 ALB DNS는 자리표시자(${...})로 두고 envsubst로 치환하는 scripts/render-k8s.sh 제공
- modules/chat: ECR(스캔 on push), EKS(terraform-aws-modules/eks 사용 가능, 인증모드 API, 실행자에 cluster admin access entry),
  managed node group, 애드온, IRSA 2개(chat, albc), LB Controller는 helm_release 또는 runbook 명령 중 택1(사유 주석)
- .github/workflows/chat-api.yml: main push(apps/chat-api/**) → OIDC로 AssumeRole → build → ECR push(태그 short SHA) → kubectl set image + rollout status
- tests/: pytest로 stub 모드 /chat 응답 7필드 검증, /scenario는 mock 서버로 검증
완료 기준: docker build 성공, `docker run -e LLM_PROVIDER=stub` 후 /chat 정상, k3d에 매니페스트 적용 시 Pod 2개 Ready(Ingress 제외)
```

## T4. 워크로드 C — note (Serverless)  (`apps/note-fn/`, `infra/terraform/modules/note`)
```
[공통 규칙]
목표: 01_CONTRACT 7장의 note 함수와 API를 만든다.
- handler.py: API GW HTTP API(payload v2) 이벤트 처리. POST /notes 검증 후 PutItem, GET /notes/{user_id} Query.
  ?crash=1 이면 로그 남기고 os._exit(1). 응답에 function 이름·request_id 포함. 콜드스타트 여부를 전역 플래그로 로그.
  env DDB_ENDPOINT가 있으면 로컬 DynamoDB 사용.
- modules/note: Lambda(VPC 연결, reserved concurrency 변수 기본 2), 실행 역할(테이블 ARN 한정), lambda-sg(egress 443 → DDB prefix list),
  HTTP API + 라우트 2개 + 통합 + Lambda permission(source_arn 한정), 액세스 로그 그룹
- tests/: pytest + amazon/dynamodb-local 컨테이너로 Put/Query 검증
완료 기준: 로컬 테스트 통과, terraform validate 통과
```

## T5. 운영·산출물 틀  (`scripts/`, `docs/`, `README.md`, `local/`)
```
[공통 규칙]
목표: 10/20~22에 내가 바로 쓸 운영 스크립트와 문서 틀을 만든다.
- scripts/bootstrap.sh: 03_CLOUDSHELL_RUNBOOK의 내용 그대로(멱등)
- scripts/ops/wait_http.sh URL [기대문자열]: 1초 간격 폴링, 성공까지 걸린 초 출력
- scripts/ops/measure.sh <환경> <작업> -- <명령...>: 시작/종료 시각과 소요 초를 docs/ops-matrix.csv에 append, 출력에 명령도 echo(캡처용)
- docs/ops-matrix.md: 3×4 표(환경×작업, 방법/명령/소요시간/무중단 여부/관찰) 빈칸 + 아래 5줄 비교 자리
- docs/constraints-check.md: C1~C10 표(충족 여부, 근거, 증적 파일명)
- docs/ADR.md: ADR-1(워크로드별 결정/맥락/이유), ADR-2(버린 대안 5개, 00_PROJECT_BRIEF 3장 기반)
- docs/cost.md: 월 비용 산정 표(EKS 컨트롤플레인, 노드, NAT, ALB×3, RDS Multi-AZ, Lambda, DDB, API GW) + 절감안 칸
- README.md: 파일 ↔ 실행 환경 매핑, 로컬 실행법, 배포 순서
- local/docker-compose.yml: mysql:8, content-api, chat-api(stub, CONTENT_API_URL=http://content-api:8080), dynamodb-local
- local/k3d-cluster.yaml: 에이전트 2개
완료 기준: `docker compose up` 후 chat-api /scenario 가 content-api 데이터를 반환(C4 로컬 리허설)
```

---

## T6. 통합 리뷰 (Opus)
```
T1~T5 결과 전체를 00·01 기준으로 검토하라.
1) C1~C10 각각 충족/미충족/불확실 + 근거 파일·라인
2) 보안: 평문 크리덴셜, 0.0.0.0/0, Resource "*", 과도한 IAM, IMDSv1
3) 계약 불일치(이름·포트·output 이름)
4) 10/20 실제 배포 시 예상 실패 지점 Top 5와 대응
5) 발견한 문제는 "AI 생성 코드 오류/취약점 수정" 사례로 docs/ai-log.md 형식으로 정리
```

## 사전 개발 완료 체크리스트 (10/19까지)
- [ ] `docker compose up` → content / chat(stub) / ddb-local 연동 OK
- [ ] k3d에 chat-api Pod 2개 Ready, Pod 삭제 시 재생성 확인(리허설)
- [ ] 각 앱 pytest 통과
- [ ] `terraform init -backend=false && terraform validate` 전 모듈 통과
- [ ] GitHub repo push (시크릿 없음 확인: `git grep -nE "AKIA|password=|secret="`)
- [ ] docs/ai-log.md 에 최소 대안비교 1건·리뷰 1건 기록
