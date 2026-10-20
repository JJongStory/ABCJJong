# 보안 스캔 결과 (2026-10-19, 사전 개발)

- 도구: checkov 3.3.29 (`checkov -d infra/terraform --framework terraform`). trivy/tflint 는 이 환경에 없어 미실행 → 10/20 CloudShell 에서 필요 시 `trivy config infra/`.
- 결과(수정 반영 후 재스캔): **통과 303 / 실패 44 / 파싱 오류 0** (리소스 108). 최초 스캔은 300/47.
- 우선 확인 대상 C6(데이터 비노출)·C7(크리덴셜)·C8(식별자 접근제어)·`Resource "*"` 직접 위반은 **0건**.

## 수정한 항목
| 항목 | 조치 |
|---|---|
| CKV2_AWS_12 기본 SG 미제한 | network 모듈에 `aws_default_security_group`(규칙 없음) 추가 — C8 보강 |
| CKV_AWS_226 / CKV2_AWS_60 RDS 마이너 자동 업그레이드·스냅샷 태그 복사 | `auto_minor_version_upgrade`, `copy_tags_to_snapshot` = true |

## 수동 점검 (스캐너 외)
| 점검 | 결과 |
|---|---|
| `0.0.0.0/0` | 라우트 2건(IGW/NAT 기본 경로), content 외부 ALB 80 인바운드 1건(**C3 유일한 예외**, 주석 명시), EC2 443 아웃바운드 1건(SSM/Secrets/S3 접근용; C8은 인바운드 소스 규칙) |
| IAM `Resource "*"` | ECR `GetAuthorizationToken` 1건(리소스 수준 권한 미지원 API) + ALBC 공식 정책(upstream 원본, 액션 80개 일치 확인). 나머지는 모두 ARN 한정 |
| 평문 비밀 | 없음 (RDS `manage_master_user_password`, IRSA/Instance Profile/OIDC) |
| 계정 ID 하드코딩 | 없음 (`git grep -E '[0-9]{12}'` 0건) |
| IMDSv2 | Launch Template `http_tokens = required` |
| SSH | 인바운드 22 없음 (SSM) |

## 수용 / 기각 사유
| 체크 | 사유 |
|---|---|
| CKV_AWS_2, 20, 103, 378 (ALB HTTP) / CKV_AWS_260 (80 열림) | 도메인·ACM 인증서 없는 PoC. 외부 ALB 80 은 C3 예외. 내부 ALB 80 은 EKS 클러스터 SG ID 소스(스캐너 오탐: CIDR 아님) |
| CKV2_AWS_28 (WAF), CKV_AWS_91 (ALB 액세스 로그), CKV_AWS_150 (ALB 삭제 보호) | 비용·정리(destroy) 편의. PoC |
| CKV_AWS_293, CKV_AWS_118, 129, 161 (RDS 삭제 보호·강화 모니터링·로그·IAM 인증) | 정리 편의, 추가 비용. 자격증명은 이미 Secrets Manager 관리형 |
| CKV_AWS_38, 39 (EKS 퍼블릭 엔드포인트) | CloudShell 이 VPC 밖이라 kubectl/helm 접근 필요. 인증은 access entry(IAM)로 보호. 대안(CIDR 제한)은 CloudShell IP 가변 |
| CKV_AWS_37 (EKS 로그 전 종류) | api+audit 만 수집(비용). 7일 보존 |
| CKV_AWS_58 (EKS 시크릿 KMS 봉투 암호화) | 앱에서 K8s Secret 미사용(시크릿은 Secrets Manager). 고객관리형 키 추가는 범위 초과 |
| CKV_AWS_26 (SNS KMS) | **기각(오히려 필요)**: CloudWatch 알람은 AWS 관리형 키(`alias/aws/sns`)로 암호화된 토픽에 Publish 불가. 알람→SNS 수신 증적(가점)을 우선. B1 서브에이전트가 넣은 KMS 설정을 제거함 |
| CKV_AWS_119, 136, 145, 158 (DDB/ECR/S3/로그 CMK) | 기본 AWS 소유/관리 키 암호화는 켜져 있음. CMK 는 비용·범위 초과 |
| CKV_AWS_338 (로그 1년 보존) | 비용. 7일 |
| CKV_AWS_18, 144, CKV2_AWS_61, 62 (S3 접근 로그·CRR·수명주기·이벤트) | artifacts 버킷은 빌드 산출물 보관용 소규모. 버전관리·퍼블릭 차단·TLS 강제·SSE 적용됨 |
| CKV_AWS_116, 173, 272, 50 (Lambda DLQ·환경변수 KMS·코드 서명·X-Ray) | 동기 API 함수, 환경변수에 비밀 없음(TABLE_NAME). 범위 초과 |
| CKV_AWS_309 (HTTP API 라우트 인증) | RFP C3: 외부 엔드포인트가 공개 접근이어야 함. 데이터 접근은 IAM 역할·DDB 리소스 정책으로 제한 |
| CKV2_AWS_11 (VPC flow logs) | 비용. 필요 시 가점용으로 추가 가능 |
