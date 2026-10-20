# 운영 체험 매트릭스 (3 환경 × 4 작업) — 발표 11장 원천

> 측정은 `scripts/ops/measure.sh`로 감싸 `docs/ops-matrix.csv`에 자동 기록된다.
> 무중단 판단은 `scripts/ops/watch_availability.sh <URL> &`를 작업 동안 백그라운드로 돌려 `docs/availability-*.csv`(200/비200 타임라인)를 근거로 한다.
> 명령은 `03_CLOUDSHELL_RUNBOOK.md` 3장과 동일. 아래 `<…>` 와 빈칸(`__`)은 실측 후 채운다.

## 측정 정의 (발표 11장에 그대로 기재)
- **시작**: 운영 명령(또는 `measure.sh`)을 입력한 시각.
- **종료**: 외부 엔드포인트(외부 ALB / Ingress ALB / API GW URL)가 **새 상태로 200 응답**한 시각. `wait_http.sh`가 걸린 초를 출력한다.
- 소요시간 = 종료 − 시작(초). 환경별로 같은 정의를 쓴다(내부 상태 "Ready"가 아니라 사용자 관점의 응답 기준).
- **무중단 여부**: 작업 중 `watch_availability.sh`가 기록한 비200 횟수 / 최장 연속 실패(초). 0 이면 "무중단".
- 같은 작업은 환경당 1회 이상 측정, 재시도 시 CSV에 행이 추가되므로 대표값을 아래 표에 옮긴다.

## 3×4 표
| 작업 | VM (EC2 ASG) | Container (EKS) | Serverless (Lambda) |
|---|---|---|---|
| **① 최초 배포** | **방법** terraform apply → ALB 200까지<br>**명령** `measure.sh vm deploy -- terraform apply -target=module.content -auto-approve` 후 `wait_http.sh "http://$(terraform output -raw content_alb_ext_dns)/" hostname`<br>**소요** __ 초 · **무중단** 해당 없음(최초)<br>**관찰** __ | **방법** kubectl apply → rollout → Ingress 200까지<br>**명령** `measure.sh container deploy -- bash -c "../../scripts/render-k8s.sh \| kubectl apply -f - && kubectl -n hermes rollout status deploy/chat-api"` 후 `wait_http.sh "http://<ingress-dns>/" pod`<br>**소요** __ 초 (클러스터 생성 `deploy-cluster` 별도 __ 초) · **무중단** 해당 없음<br>**관찰** __ | **방법** terraform apply → 첫 201까지<br>**명령** `measure.sh serverless deploy -- terraform apply -target=module.note -auto-approve` 후 `POST $(terraform output -raw note_api_url)/notes`<br>**소요** __ 초 · **무중단** 해당 없음<br>**관찰** __ |
| **② 재배포** (코드 1줄 수정) | **방법** APP_VERSION 변경 → apply(zip 업로드·LT 새 버전) → instance refresh<br>**명령** `aws autoscaling start-instance-refresh --auto-scaling-group-name user17-hermes-content-asg --preferences MinHealthyPercentage=100,MaxHealthyPercentage=200` → `wait_http.sh … <새 version>`<br>**소요** __ 초 · **무중단** __ (비200 __회)<br>**관찰** __ | **방법** 새 이미지 태그 → 롤링 업데이트<br>**명령** `kubectl -n hermes set image deploy/chat-api chat-api=$ECR:<sha>` → `kubectl -n hermes rollout status deploy/chat-api`<br>**소요** __ 초 · **무중단** __ (비200 __회)<br>**관찰** __ | **방법** 함수 코드 교체<br>**명령** `aws lambda update-function-code --function-name user17-hermes-note-fn --zip-file fileb://note.zip && aws lambda wait function-updated --function-name user17-hermes-note-fn`<br>**소요** __ 초 · **무중단** __ (비200 __회)<br>**관찰** __ |
| **③ 강제 종료 복구** (C9) | **방법** 인스턴스 terminate → ASG 재생성<br>**명령** `aws ec2 terminate-instances --instance-ids <id>` → ALB 200까지(`wait_http.sh`)<br>**소요** __ 초 · **무중단** 아니오 예상(단일 인스턴스, 다운타임 기록: __ 초)<br>**관찰** 전·후 캡처: 인스턴스 ID/hostname 변경 __ | **방법** Pod 삭제 → ReplicaSet 복원<br>**명령** `kubectl -n hermes delete pod <pod>` → `kubectl -n hermes get pods -w`<br>**소요** 새 Pod Ready까지 __ 초 · **무중단** __ (다른 replica 응답 유지)<br>**관찰** 전·후 캡처: Pod 이름 변경 __ | **방법** 실행 환경 강제 종료 후 재요청<br>**명령** `curl -XPOST "$NOTE/notes?crash=1"` (502) → 즉시 `POST /notes` 201<br>**소요** 다음 요청 성공까지 __ 초 · **무중단** 1회 실패 예상<br>**관찰** CloudWatch 로그 INIT(콜드스타트)로 새 환경 증명 __ |
| **④ 용량 2배** | **방법** desired 1 → 2<br>**명령** `aws autoscaling set-desired-capacity --auto-scaling-group-name user17-hermes-content-asg --desired-capacity 2`<br>**소요** TG healthy 2개까지 __ 초 · **무중단** __<br>**관찰** __ | **방법** replica 2 → 4 (HPA minReplicas)<br>**명령** `kubectl -n hermes patch hpa chat-api -p '{"spec":{"minReplicas":4}}'` (HPA 없으면 `kubectl scale --replicas=4`)<br>**소요** Ready 4까지 __ 초 · **무중단** __<br>**관찰** __ | **방법** reserved concurrency 2 → 4<br>**명령** `aws lambda put-function-concurrency --function-name user17-hermes-note-fn --reserved-concurrent-executions 4`<br>**소요** 즉시(__ 초) · **무중단** 해당 없음<br>**관찰** __ |

> 표의 수치는 CSV의 대표값을 옮긴 것이며, 캡처에는 주소창 또는 실행 명령이 함께 보여야 한다(계정 ID·ARN 마스킹).

## 세 환경 비교 (5줄) — 발표 12장
1. 배포 속도: __
2. 재배포 중 가용성(무중단 여부): __
3. 장애 복구 방식과 시간: __
4. 용량 증설의 속도와 단위: __
5. 운영 부담·비용 구조(유휴 비용 포함): __
