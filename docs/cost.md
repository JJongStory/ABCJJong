# 월 비용 산정 (서울 리전 ap-northeast-2) — 발표 15장 원천

> **단가는 모두 "AWS 공식 요금 페이지 기준 확인 필요"** (10/20 실제 조회 후 기입). 산식은 미리 작성했으며 단가 칸(`__`)만 채우면 합계가 나온다.
> 월 환산 시간 = **730h**. 환율·세금 제외. 사용량 가정은 PoC(상시 기동, 낮은 트래픽).

| # | 항목 | 사용량 가정 | 산식 | 단가 (확인 필요) | 월 비용 (USD) |
|---|---|---|---|---|---|
| 1 | EKS 컨트롤플레인 | 1 클러스터 × 730h | 730 × 시간당 단가 | `__` /h | `__` |
| 2 | EKS 노드 t3.medium | 2대 × 730h (최대 4) | 2 × 730 × 단가 | `__` /h | `__` |
| 3 | EC2 content t3.micro | 1대 × 730h (최대 2) | 1 × 730 × 단가 | `__` /h | `__` |
| 4 | EBS gp3 | 노드 2×20GB + EC2 8GB(가정) | GB 합 × GB당 단가 | `__` /GB | `__` |
| 5 | NAT GW 1개 | 730h + 처리 데이터 `__` GB | 730 × 시간 단가 + GB × 처리 단가 | `__` /h, `__` /GB | `__` |
| 6 | 공인 IPv4 (NAT EIP, ALB) | `__` 개 × 730h | 개수 × 730 × 단가 | `__` /h | `__` |
| 7 | ALB × 3 (외부 content, 내부 content, Ingress chat) | 3 × 730h + LCU `__` | 3 × 730 × 시간 단가 + LCU 합 × LCU 단가 | `__` /h, `__` /LCU | `__` |
| 8 | RDS MySQL Multi-AZ | db.t3.micro Multi-AZ × 730h + 스토리지 20GB | 730 × 시간 단가(Multi-AZ) + 20 × GB 단가 | `__` /h, `__` /GB | `__` |
| 9 | Lambda | 월 요청 `__` 건, 128MB, 평균 `__` ms | 요청수 × 요청 단가 + GB-초 × 단가 (프리티어 차감) | `__` | `__` |
| 10 | DynamoDB On-Demand | 읽기 `__`건, 쓰기 `__`건, 저장 `__` GB | 쓰기 × WRU + 읽기 × RRU + GB × 단가 | `__` | `__` |
| 11 | API Gateway HTTP API | 월 `__` 백만 요청 | 요청(백만) × 단가 | `__` /백만 | `__` |
| 12 | ECR | 이미지 `__` GB | GB × 단가 | `__` /GB | `__` |
| 13 | CloudWatch (로그·알람·Flow Log) | 로그 `__` GB, 알람 3개 | GB × 수집 단가 + 알람 수 × 단가 | `__` | `__` |
| 14 | Secrets Manager / KMS | 시크릿 1(RDS 관리형), CMK 1 | 개수 × 월 단가 | `__` | `__` |
| | **합계 (24h×30일 상시 기동)** | | Σ 1~14 | | `__` |
| | **실습 3일(72h) 환산** | | 합계 ÷ 730 × 72 | | `__` |

## 절감안 (효과는 실측 단가 기입 후 계산)
| 절감안 | 방법 | 예상 효과 | 포기하는 것 |
|---|---|---|---|
| Spot 노드 | EKS managed NG를 Spot capacity type으로 | 노드 비용 `__`% ↓ | 노드 회수 시 Pod 재스케줄 |
| NAT 대신 VPC Endpoint 확대 | S3/DynamoDB Gateway는 이미 적용. ECR·Secrets Manager·SSM Interface Endpoint 추가 | NAT 처리 데이터 `__` GB ↓ (Endpoint 시간 요금과 비교 필요) | Endpoint 시간 요금, 설정 복잡도 |
| 야간 스케일다운 | NG desired 0, ASG desired 0, RDS stop(Multi-AZ는 stop 제약 확인) | 야간 `__`h × 시간 단가 | 야간 서비스 불가 |
| 단일 AZ NAT 유지 | 이미 적용(ADR-2 #4) | NAT 1개분 절감 | AZ 장애 내성 |
| RDS 단일 AZ (개발용) | multi_az=false | RDS 비용 약 `__`% ↓ | 요구사항상 Multi-AZ 근거 약화 → **제출 환경에서는 비권장** |
| Savings Plan / RI | 상시 구동 컴퓨팅 | `__`% ↓ | 약정 기간 |
| 로그 보존 단축 | 로그 그룹 14일 → 7일 | CloudWatch 저장 `__` ↓ | 장애 분석 기간 |

## 비고
- 비용의 대부분은 EKS 컨트롤플레인·NAT·ALB·RDS Multi-AZ의 **상시 고정비**로 예상된다(사용량 비례 비용은 작음). 확인은 Cost Explorer 또는 가격 계산기로 한다.
- 정리(destroy) 후 잔존 과금 점검: NAT/EIP, ALB(Ingress가 만든 것), CloudWatch 로그 그룹, 스냅샷.
