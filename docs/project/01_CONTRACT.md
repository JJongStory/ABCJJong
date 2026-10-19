# 01. INTERFACE CONTRACT — Project HERMES

> 병렬 Task(T1~T5)가 공유하는 **고정 규약**. 여기 적힌 이름·값은 모든 코드·IaC·문서에서 그대로 쓴다.
> 변경은 기획(Opus) 단계에서만, 변경 이력은 맨 아래 표에 기록.

## 1. 공통
| 항목 | 값 |
|---|---|
| 리전 / AZ | `ap-northeast-2` / `ap-northeast-2a`, `ap-northeast-2c` |
| 이름 접두사 | `hermes-prd` |
| 네이밍 규칙 | `hermes-{env}-{workload}-{resource}[-{az}]` 예) `hermes-prd-content-ec2-a`, `hermes-prd-chat-ecr` |
| workload 값 | `shared`(네트워크·공통) / `content` / `chat` / `note` |
| 필수 태그 (provider default_tags) | `Project=HERMES`, `Owner=parkjongho`, `Env=prd`, `ManagedBy=terraform` |
| 리소스별 태그 | `Workload={shared\|content\|chat\|note}`, `ComputeType={none\|vm\|container\|serverless}` |
| Terraform | >= 1.10, AWS provider ~> 6.x (10/20 최신 확인), state = S3 backend + `use_lockfile = true` |
| state 버킷 | `hermes-tfstate-<random6>` (계정 ID를 이름에 넣지 않는다 — 캡처 노출 방지) |

## 2. 네트워크
| 이름 | CIDR | AZ | 용도 | 비고 |
|---|---|---|---|---|
| `hermes-prd-shared-vpc` | 10.0.0.0/16 | - | 단일 VPC | DNS hostnames/support on |
| `hermes-prd-shared-pub-a` | 10.0.0.0/24 | 2a | 외부 ALB, NAT GW | tag `kubernetes.io/role/elb=1` |
| `hermes-prd-shared-pub-c` | 10.0.1.0/24 | 2c | 외부 ALB | tag `kubernetes.io/role/elb=1` |
| `hermes-prd-shared-app-a` | 10.0.16.0/20 | 2a | EC2, EKS 노드/Pod, Lambda ENI, 내부 ALB | tag `kubernetes.io/role/internal-elb=1` |
| `hermes-prd-shared-app-c` | 10.0.32.0/20 | 2c | 〃 | 〃 |
| `hermes-prd-shared-data-a` | 10.0.100.0/24 | 2a | RDS | 인터넷 경로 없음 |
| `hermes-prd-shared-data-c` | 10.0.101.0/24 | 2c | RDS | 인터넷 경로 없음 |

- 서브넷 크기 근거: EKS VPC CNI는 Pod마다 VPC IP를 소비 → app 계층 /20(4,091 IP). 공개·데이터 계층은 ALB/NAT/RDS만 있어 /24로 충분. 10.0.48.0/20 등은 확장 여유.
- 라우팅: pub → IGW / app → NAT GW 1개(`hermes-prd-shared-nat-a`, 비용 트레이드오프 ADR-2) / data → 로컬만
- VPC Endpoint (Gateway): `hermes-prd-shared-vpce-s3`, `hermes-prd-shared-vpce-ddb` (app 라우트테이블에 연결)

## 3. Security Group 매트릭스 (C8: 소스는 SG ID만)
| SG 이름 | Inbound | Source | 비고 |
|---|---|---|---|
| `hermes-prd-content-alb-ext-sg` | TCP 80 | 0.0.0.0/0 | **유일한 IP 대역 예외** (C3 외부 엔드포인트) |
| `hermes-prd-content-alb-int-sg` | TCP 80 | **EKS cluster SG ID** | C4 연동 경로. Pod는 노드 ENI SG(cluster SG)를 사용 |
| `hermes-prd-content-ec2-sg` | TCP 8080 | `content-alb-ext-sg`, `content-alb-int-sg` | SSH(22) 인바운드 없음 → SSM 사용 |
| `hermes-prd-shared-rds-sg` | TCP 3306 | `content-ec2-sg` | |
| `hermes-prd-note-lambda-sg` | (없음) | - | Egress 443 → DynamoDB prefix list ID |
| EKS cluster SG | (EKS 관리) | - | Ingress ALB SG는 AWS LB Controller가 생성·관리 |

## 4. 데이터 저장소
### RDS (C5 관계형)
| 항목 | 값 |
|---|---|
| 식별자 | `hermes-prd-shared-rds` (MySQL 8.0, db.t3.micro 또는 db.t4g.micro, **Multi-AZ**) |
| 서브넷 그룹 | `hermes-prd-shared-rds-subnets` (data-a, data-c) |
| DB / 사용자 | `hermes` / `hermes_admin` |
| 비밀번호 | `manage_master_user_password = true` → **RDS 관리형 시크릿**(Secrets Manager, 이름 자동 `rds!db-...`) |
| 공개 | `publicly_accessible = false` |

테이블 (content-api가 기동 시 `CREATE TABLE IF NOT EXISTS` + 비어 있으면 seed 3건):
```sql
CREATE TABLE IF NOT EXISTS scenarios (
  id INT AUTO_INCREMENT PRIMARY KEY,
  topic VARCHAR(100) NOT NULL,      -- 예: cafe, airport, small-talk
  level VARCHAR(20) NOT NULL,       -- beginner|intermediate
  opener_en TEXT NOT NULL,          -- 봇의 첫 문장
  opener_ko TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### DynamoDB (C5 NoSQL)
| 항목 | 값 |
|---|---|
| 테이블 | `hermes-prd-note-ddb` (On-Demand) |
| 키 | PK `user_id` (S), SK `created_at` (S, ISO8601) |
| 속성 | `wrong` (S, 틀린 표현), `correct` (S), `memo` (S, optional) |
| 접근 | Lambda 실행 역할만 PutItem/Query (+권장 테이블 정책: `aws:SourceVpce` = ddb 엔드포인트 OR 관리자 Role) |

## 5. 워크로드 A — content (VM)
| 항목 | 값 |
|---|---|
| 런타임 | Amazon Linux 2023, Python 3 + FastAPI + uvicorn, systemd `content-api.service`, **포트 8080** |
| 기동 | Launch Template `hermes-prd-content-lt` + **User Data** (사람 접속 금지) |
| 코드 배포 | `s3://hermes-prd-shared-artifacts-<random6>/content/content-api-<ver>.zip` → User Data가 내려받아 실행 |
| ASG | `hermes-prd-content-asg` min 1 / desired 1 / max 2, app-a·app-c, health check = ELB, grace 120s |
| 외부 ALB | `hermes-prd-content-alb-ext` (pub 서브넷) → TG `hermes-prd-content-tg-ext` |
| 내부 ALB | `hermes-prd-content-alb-int` (app 서브넷, internal) → TG `hermes-prd-content-tg-int` |
| 인스턴스 역할 | `hermes-prd-content-ec2-role` : `AmazonSSMManagedInstanceCore`, `secretsmanager:GetSecretValue`(RDS 시크릿 ARN 한정), `s3:GetObject`(artifacts/content/*) |
| 주입값 (User Data 템플릿 변수, 비밀 아님) | `DB_HOST`, `DB_NAME`, `DB_SECRET_ARN`, `ARTIFACT_URI`, `APP_VERSION`, `AWS_REGION` |

API:
| Method | Path | 응답 |
|---|---|---|
| GET | `/health` | `{"status":"ok"}` (DB 연결 실패해도 200 — 프로세스 생존 확인용) |
| GET | `/` | `{"service":"content-api","version":APP_VERSION,"hostname":<hostname>,"az":<IMDSv2 AZ>,"sample":<scenarios 1건>}` ← **요구사항 2 증적** |
| GET | `/scenarios` | `[{"id","topic","level","opener_en","opener_ko"}]` |
| GET | `/scenarios/{id}` | 단건, 없으면 404 |

## 6. 워크로드 B — chat (Container / EKS)
| 항목 | 값 |
|---|---|
| ECR | `hermes-prd-chat-ecr` (이미지 태그 = git short SHA, `latest` 미사용) |
| EKS 클러스터 | `hermes-prd-chat-eks` (버전: 10/20 기준 최신 standard), 인증 모드 `API` (access entry) |
| 노드그룹 | `hermes-prd-chat-ng` t3.medium, min 2 / desired 2 / max 4, app-a·app-c |
| 애드온 | vpc-cni, coredns, kube-proxy, eks-pod-identity-agent(선택), metrics-server |
| LB Controller | Helm `aws-load-balancer-controller`, SA `kube-system/aws-load-balancer-controller`, IRSA `hermes-prd-chat-albc-role` |
| 네임스페이스 / SA | `hermes` / `chat-api` (IRSA `hermes-prd-chat-irsa-role`) |
| Deployment | `chat-api`, **replicas 2**, containerPort **8000**, liveness/readiness `GET /health`, zone topologySpread, requests cpu 100m/mem 128Mi |
| Service | `chat-api` ClusterIP 80 → 8000 |
| Ingress | `chat-api`, class `alb`, `scheme: internet-facing`, `target-type: ip`, healthcheck `/health` |
| HPA | min 2 / max 6, CPU 60% (가점용) |

환경변수 (ConfigMap `chat-api-config`, 비밀 아님):
| 키 | 값 |
|---|---|
| `CONTENT_API_URL` | `http://<hermes-prd-content-alb-int DNS>` |
| `NOTE_API_URL` | `https://<API GW URL>` (선택 연동) |
| `LLM_PROVIDER` | `bedrock` \| `gemini` \| `stub` (기본 `bedrock`, 실패 시 자동 stub 폴백) |
| `BEDROCK_MODEL_ID` | Claude Haiku 4.5 Global 추론 프로파일 ID (10/20에 `aws bedrock list-inference-profiles`로 확정) |
| `GEMINI_SECRET_ID` | `hermes/prd/chat/gemini-api-key` (gemini 사용 시에만, Secrets Manager) |
| `AWS_REGION` | `ap-northeast-2` |

IRSA 역할 `hermes-prd-chat-irsa-role` 권한: `bedrock:InvokeModel`, `bedrock:Converse`(Haiku 4.5 프로파일·파운데이션모델 ARN 한정), `secretsmanager:GetSecretValue`(gemini 시크릿 ARN 한정, 선택), `execute-api:Invoke`(note API ARN, 선택)

API:
| Method | Path | 요청 / 응답 |
|---|---|---|
| GET | `/health` | `{"status":"ok"}` |
| GET | `/` | `{"service":"chat-api","pod":$HOSTNAME,"version":...,"llm_provider":...}` ← **요구사항 3 증적(컨테이너 이름)** |
| GET | `/scenario` | content-api `/scenarios` 호출 결과를 감싸서 반환: `{"pod","upstream":"content-api","upstream_hostname","data":[...]}` ← **C4 증적** |
| POST | `/chat` | 요청 `{"message":"(한글)","history":[{"role","content"}...최대 6개],"scenario_id":opt}` → 응답 `{"input_en","input_pron","reply_en","reply_pron","reply_ko","topic","llm_provider"}` |
| POST | `/note` (선택) | note API로 프록시 저장 |

- 무상태: 대화 이력은 클라이언트가 `history`로 전달(슬라이딩 윈도우 6개). Pod 간 세션 공유 불필요 → 수평 확장 근거.
- LLM 호출은 `llm.py` 어댑터로 분리. 예외·타임아웃(10s) 시 stub 응답, `llm_provider: "stub(fallback)"`.

## 7. 워크로드 C — note (Serverless)
| 항목 | 값 |
|---|---|
| API | API Gateway **HTTP API** `hermes-prd-note-api`, stage `$default` |
| 라우트 | `POST /notes`, `GET /notes/{user_id}` → Lambda 프록시 통합 |
| 함수 | `hermes-prd-note-fn`, Python 3.12, 128MB, timeout 10s, **VPC 연결(app-a, app-c, `note-lambda-sg`)** |
| 실행 역할 | `hermes-prd-note-fn-role`: `AWSLambdaVPCAccessExecutionRole` + `dynamodb:PutItem`,`dynamodb:Query`(테이블 ARN 한정) |
| 환경변수 | `TABLE_NAME=hermes-prd-note-ddb` |
| 동시성 | reserved concurrency 2 (증설 실험: 2 → 4) |

API:
| Method | Path | 요청 / 응답 |
|---|---|---|
| POST | `/notes` | `{"user_id","wrong","correct","memo"?}` → `201 {"saved":{...},"function":"hermes-prd-note-fn","request_id":...}` |
| GET | `/notes/{user_id}` | `{"user_id","count","items":[...]}` |
| POST | `/notes?crash=1` | (복구 실험용) 실행 환경 강제 종료 `os._exit(1)` → 다음 호출이 새 실행 환경에서 성공함을 증명 |

## 8. 시크릿 / 파라미터
| 이름 | 종류 | 사용처 |
|---|---|---|
| RDS 관리형 시크릿 (`rds!db-...`) | Secrets Manager | content EC2 (ARN을 User Data 변수로 전달) |
| `hermes/prd/chat/gemini-api-key` | Secrets Manager (선택) | chat Pod (IRSA) |

## 9. IAM Role 목록
| Role | 신뢰 주체 | 용도 |
|---|---|---|
| `hermes-prd-content-ec2-role` | ec2.amazonaws.com | A 인스턴스 |
| `hermes-prd-chat-irsa-role` | EKS OIDC, SA `hermes:chat-api` | B Pod |
| `hermes-prd-chat-albc-role` | EKS OIDC, SA `kube-system:aws-load-balancer-controller` | LB Controller |
| `hermes-prd-note-fn-role` | lambda.amazonaws.com | C 함수 |
| `hermes-prd-shared-gha-role` (선택) | GitHub OIDC, repo `JJongStory/ABCJJong`, branch main | CI: ECR push + EKS 배포 |

## 10. 리포지토리 구조
```
ABCJJong/  (CloudShell에선 ~/hermes 로 clone)
├─ README.md                      # 파일 ↔ 실행 환경 매핑 (RFP 소스 제출 요건)
├─ docs/  ADR.md  ops-matrix.md  constraints-check.md  ai-log.md  cost.md  evidence/
├─ apps/
│  ├─ content-api/   app.py requirements.txt  userdata.sh.tftpl  content-api.service  tests/
│  ├─ chat-api/      app.py llm.py requirements.txt Dockerfile tests/
│  └─ note-fn/       handler.py tests/
├─ k8s/              namespace.yaml serviceaccount.yaml configmap.yaml deployment.yaml service.yaml ingress.yaml hpa.yaml
├─ infra/terraform/  backend.tf providers.tf variables.tf main.tf outputs.tf
│  └─ modules/       network/ data/ content/ chat/ note/ monitoring/
├─ local/            docker-compose.yml  k3d-cluster.yaml
├─ scripts/          bootstrap.sh  ops/measure.sh  ops/wait_http.sh
└─ .github/workflows/chat-api.yml
```

## 11. Terraform 모듈 I/O (모듈 간 이름 고정)
| 모듈 | 주요 outputs (다른 모듈이 사용) |
|---|---|
| network | `vpc_id`, `public_subnet_ids`, `app_subnet_ids`, `data_subnet_ids`, `app_route_table_ids`, `ddb_prefix_list_id`, `vpce_ddb_id` |
| data | `rds_endpoint`, `rds_secret_arn`, `rds_sg_id`, `ddb_table_name`, `ddb_table_arn`, `artifacts_bucket` |
| chat | `eks_cluster_name`, `eks_cluster_sg_id`, `oidc_provider_arn`, `ecr_repo_url`, `chat_irsa_role_arn`, `albc_role_arn` |
| content | `content_alb_ext_dns`, `content_alb_int_dns`, `content_ec2_sg_id`, `content_asg_name` |
| note | `note_api_url`, `note_fn_name`, `note_api_arn` |
| monitoring | `sns_topic_arn` |
루트 outputs는 위 값 전부를 같은 이름으로 재노출한다(runbook이 `terraform output -raw <이름>`으로 사용).
의존 순서: network → data → chat(EKS) → content(내부 ALB SG가 `eks_cluster_sg_id` 필요) → note → monitoring

## 12. 변경 이력
| 날짜 | 변경 | 사유 |
|---|---|---|
| 2026-10-14 | 초안 | 수행계획서 기반 |
| 2026-10-19 | 메인 저장소 확정: github.com/JJongStory/ABCJJong (public). 문서는 docs/project/, AI 로그는 docs/ai-log.md | 저장소 생성 |
