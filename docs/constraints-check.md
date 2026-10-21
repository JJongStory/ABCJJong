# 제약 점검표 C1~C10 — 발표 14장 원천

> 증적 번호(E**)는 발표자료에 삽입한 캡처 번호. 캡처에는 주소창 또는 실행 명령이 함께 보이며, 계정 ID·액세스 키·비밀번호·ARN은 가렸다.

| No | 제약 | 충족 | 근거 | 증적 |
|---|---|---|---|---|
| C1 | 단일 VPC·다중 AZ | ✅ | VPC 1개(10.0.0.0/16), 서브넷 6개가 2a·2c. EC2 ASG·EKS 노드·Lambda(VPC 연결)·RDS Multi-AZ 모두 2AZ | E19, E20, E02, E05 |
| C2 | 세 컴퓨팅 유형 사용 | ✅ | 콘텐츠 = EC2, 챗봇 = EKS, 기록 = Lambda | 발표 6·7·8장 |
| C3 | 유형별 외부 엔드포인트 | ✅ | 외부 ALB(콘텐츠), Ingress ALB(챗봇), API Gateway(기록) | E01, E04, E07 |
| C4 | 이종 워크로드 간 데이터 연동 | ✅ | 챗봇 Pod → 내부 ALB → 콘텐츠 EC2 → RDS. 응답의 `upstream_hostname`이 EC2 hostname | E09, E23 |
| C5 | 영속 저장소 2종 | ✅ | RDS MySQL(관계형 시나리오) + DynamoDB(키 기반 기록, 사용량 과금) | E01, E07 |
| C6 | 데이터 계층 비노출 | ✅ | RDS: 데이터 서브넷, `PubliclyAccessible=false`, 콘텐츠 EC2 SG만 허용. DynamoDB: 실행 역할 최소권한 + Gateway Endpoint, 테이블 리소스 정책으로 엔드포인트 밖 데이터 평면 접근 거부 | E20 |
| C7 | 크리덴셜 외부화 | ✅ | RDS 관리형 시크릿(Secrets Manager) + 인스턴스 역할, IRSA, Lambda 실행 역할. 액세스 키 미발급, 코드·IaC·매니페스트 평문 크리덴셜 0건 | E11, E12 |
| C8 | 자원 식별자 기반 접근 제어 | ✅ | SG 소스는 SG ID만(외부 ALB 80만 예외). 내부 ALB 인바운드 = EKS cluster SG. IAM은 리소스 ARN 한정(ALBC·ECR 인증 토큰은 API 특성상 예외, 주석에 사유) | E10 |
| C9 | 자동 복구 실증 | ✅ | EC2 terminate → ASG 재생성(178.1초), Pod delete → ReplicaSet 재생성(7.7초) | E13~E16 |
| C10 | 환경 및 완주 | ✅ | ap-northeast-2와 배정 계정만 사용, 모든 자원 이름 접두사 `user17-hermes`, 마감 시점 전 구간 동작 | 전체 |

## 네트워크 설계 근거
- **서브넷 크기**: 앱 계층 /20(4,091 IP) — EKS VPC CNI가 Pod마다 VPC IP를 쓰므로 노드·Pod 증설 여유 확보. 퍼블릭(ALB·NAT)과 데이터(RDS)는 /24. 10.0.48.0/20 이후는 확장 여유.

| 계층 | 2a | 2c |
|---|---|---|
| 퍼블릭 | 10.0.0.0/24 | 10.0.1.0/24 |
| 프라이빗 앱 | 10.0.16.0/20 | 10.0.32.0/20 |
| 프라이빗 데이터 | 10.0.100.0/24 | 10.0.101.0/24 |

- **네이밍**: `user17-hermes-{기능}-{자원}[-{AZ}]`
- **태그**: Project, Owner, Env, ManagedBy, Workload, ComputeType (기능별 비용 배분 기준)
