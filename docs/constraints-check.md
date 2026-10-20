# 제약 점검표 C1~C10 — 발표 13장 원천

> 위반 시 해당 항목 0점. 설계 근거는 `00_PROJECT_BRIEF.md` 4장. **충족 여부**는 마감 전 실제 증적으로 확인 후 체크한다.

| No | 제약 | 충족 여부 | 설계상 근거 | 증적 파일명 (`docs/evidence/`) |
|---|---|---|---|---|
| C1 | 단일 VPC·다중 AZ | ☐ | VPC 1개, 2a/2c. EC2 ASG·EKS 노드·**Lambda(VPC 연결)**·RDS Multi-AZ 모두 2AZ | `c1-vpc-subnets.png`, `c1-lambda-vpc.png` |
| C2 | 세 컴퓨팅 유형 사용 | ☐ | A=EC2, B=EKS, C=Lambda | `c2-ec2-asg.png`, `c2-eks-pods.png`, `c2-lambda.png` |
| C3 | 유형별 외부 엔드포인트 ≥1 (총 3) | ☐ | 외부 ALB(A), Ingress ALB(B), API GW URL(C) | `c3-content-root.png`, `c3-chat-root.png`, `c3-note-post.png` |
| C4 | 이종 워크로드 간 데이터 연동 ≥1 | ☐ | **B(Pod) → 내부 ALB → A**(시나리오 조회). (선택) B → C 오답노트 저장 | `c4-chat-scenario.png` (upstream_hostname = EC2 hostname) |
| C5 | 영속 저장소 2종 | ☐ | RDS MySQL(관계형) + DynamoDB(NoSQL) | `c5-rds.png`, `c5-ddb-items.png` |
| C6 | 데이터 계층 비노출 | ☐ | RDS: private data 서브넷, publicly_accessible=false, SG는 A의 SG만. DynamoDB: IAM 최소권한 + Gateway Endpoint (+테이블 정책 aws:SourceVpce 제한) | `c6-rds-sg.png`, `c6-rds-public-false.png`, `c6-ddb-policy.png` |
| C7 | 크리덴셜 외부화 | ☐ | RDS 관리형 시크릿(Secrets Manager), IAM Role(Instance Profile/IRSA/Lambda Role). Access Key 미발급 | `c7-rds-secret.png`, `c7-iam-roles.png`, `c7-git-grep.txt` |
| C8 | 자원 식별자 기반 접근 제어 | ☐ | SG 소스는 **SG ID만** (외부 ALB 80/443만 0.0.0.0/0 예외), IAM 정책 리소스 ARN 한정 | `c8-sg-rules.png`, `c8-iam-policy.png` |
| C9 | 자동 복구 실증 | ☐ | EC2 terminate → ASG 재생성 / Pod delete → ReplicaSet 복원 (전·후 캡처) | `c9-vm-before.png`, `c9-vm-after.png`, `c9-pod-before.png`, `c9-pod-after.png` |
| C10 | 환경 및 완주 | ☐ | ap-northeast-2·지정 계정만, 마감 시 E2E 동작 | `c10-e2e.png`, `c10-region.png` |

## 점검 메모
- C3 외부 ALB 80 외 IP 대역 인바운드가 없음을 SG 목록에서 확인 (C8과 같은 캡처 활용).
- C7: `git grep -nE "AKIA|password=|secret="` 결과 0건 로그를 증적으로 남긴다.
- 캡처 규칙: 주소창/명령 포함, 복구는 전·후 나란히, 계정 ID·Access Key·비밀번호 마스킹.
