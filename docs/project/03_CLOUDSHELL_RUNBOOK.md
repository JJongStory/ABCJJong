# 03. CLOUDSHELL RUNBOOK — 10/20~10/22 실행 절차

> 모든 작업은 AWS CloudShell(서울)에서. 콘솔이 필요한 건 **SNS 메일 구독 확인, MFA, 브라우저 캡처**뿐.
> 캡처 전 확인: 계정 ID·ARN·Access Key가 화면에 없을 것 (`sts get-caller-identity`, ARN 출력 명령은 캡처 금지).

## 0. CloudShell 제약 (반드시 숙지)
| 제약 | 대응 |
|---|---|
| 1 vCPU / 2GB RAM | 이미지 빌드는 GitHub Actions 우선, CloudShell docker는 백업 |
| `$HOME` 1GB 영속, 그 외 경로는 세션 종료 시 삭제 | provider는 `/tmp`(TF_DATA_DIR). state는 S3 |
| **무입력 20~30분 → 세션 종료** (실행 중 프로세스는 활동으로 안 침) | EKS apply(15~20분) 중 탭 유지·주기적 입력. 끊기면 `terraform apply` 재실행(멱등) — state lock 남으면 `terraform force-unlock` |
| 최대 세션 ~12시간 | 매일 아침 `source ~/hermes/scripts/bootstrap.sh` |
| Docker 지원은 리전별 상이 | Day 1 아침 `docker info`로 확인 |

## 1. Day 1 (10/20) — 기반 + VM
```bash
# 1) 준비
git clone https://github.com/JJongStory/ABCJJong.git ~/hermes   # 로컬 디렉터리명은 hermes로 통일
source ~/hermes/scripts/bootstrap.sh

# 2) 계정 정책 사전 점검 (막히는 것 조기 발견 → 강사 문의)
aws bedrock list-inference-profiles --query "inferenceProfileSummaries[?contains(inferenceProfileId,'haiku-4-5')].inferenceProfileId" --output text
aws bedrock-runtime converse --model-id <위 ID> --messages '[{"role":"user","content":[{"text":"hi"}]}]' --query 'output.message.content[0].text'
aws iam list-open-id-connect-providers >/dev/null && echo "IAM 조회 OK"
#   실패 시: LLM_PROVIDER=stub(또는 gemini)로 전환, IAM Role/OIDC 생성 권한은 강사에 확인

# 3) state 버킷 (1회)
SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n'); TFB=hermes-tfstate-$SUF
aws s3api create-bucket --bucket $TFB --create-bucket-configuration LocationConstraint=ap-northeast-2
aws s3api put-bucket-versioning --bucket $TFB --versioning-configuration Status=Enabled
echo "export TFB=$TFB" >> ~/.bashrc

# 4) 인프라 (의존 순서: network → data → chat → content → note → monitoring)
cd ~/hermes/infra/terraform
terraform init -backend-config="bucket=$TFB" -backend-config="key=hermes/prd.tfstate" -backend-config="region=ap-northeast-2"
../../scripts/ops/measure.sh shared deploy -- terraform apply -target=module.network -target=module.data -auto-approve
../../scripts/ops/measure.sh container deploy-cluster -- terraform apply -target=module.chat -auto-approve   # 15~20분, 탭 유지!
../../scripts/ops/measure.sh vm deploy -- terraform apply -target=module.content -auto-approve
../../scripts/ops/wait_http.sh "http://$(terraform output -raw content_alb_ext_dns)/" hostname
```
→ VM 최초 배포 완료. **캡처: 브라우저 주소창 + `/` 응답(hostname, sample)**

## 2. Day 2 (10/21) — Container + Serverless + 연동
```bash
source ~/hermes/scripts/bootstrap.sh && cd ~/hermes/infra/terraform && terraform init -backend-config=... (위와 동일)

# Container: LB Controller (helm_release로 안 했다면)
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=hermes-prd-chat-eks --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw albc_role_arn) \
  --set region=ap-northeast-2 --set vpcId=$(terraform output -raw vpc_id)

# 이미지: GitHub Actions(main push) 또는 CloudShell 백업 빌드
#   ECR=$(terraform output -raw ecr_repo_url); aws ecr get-login-password | docker login --username AWS --password-stdin ${ECR%/*}
#   docker build -t $ECR:$(git rev-parse --short HEAD) ../../apps/chat-api && docker push ...
# render-k8s.sh 필수 env (T6 추가 — 없으면 '필수 환경변수 미설정'으로 실패). 첫 이미지는 Actions workflow_dispatch(이미지 push 후 deploy 단계는 Deployment 가 아직 없어 실패 — 예상된 동작) 또는 CloudShell 백업 빌드
export IMAGE=$(terraform output -raw ecr_repo_url):<short-sha>                 # latest 금지
export CHAT_IRSA_ROLE_ARN=$(terraform output -raw chat_irsa_role_arn)          # 캡처 금지(계정 ID)
export CONTENT_API_URL=http://$(terraform output -raw content_alb_int_dns)     # 계약 6장: http:// 포함 (C4 경로)
export BEDROCK_MODEL_ID=<1-2)에서 확정한 ID>   # terraform.tfvars 의 bedrock_model_id 와 반드시 동일 (IRSA 권한 범위)
export NOTE_API_URL=                            # note 배포 후 $(terraform output -raw note_api_url) 로 채우고 render|apply 재실행
../../scripts/ops/measure.sh container deploy -- bash -c "../../scripts/render-k8s.sh | kubectl apply -f - && kubectl -n hermes rollout status deploy/chat-api"
kubectl -n hermes get ingress chat-api   # ALB 프로비저닝 2~3분
../../scripts/ops/wait_http.sh "http://<ingress-dns>/" pod

# Serverless
../../scripts/ops/measure.sh serverless deploy -- terraform apply -target=module.note -auto-approve
curl -s -XPOST "$(terraform output -raw note_api_url)/notes" -H 'content-type: application/json' \
  -d '{"user_id":"demo","wrong":"I am agree","correct":"I agree"}'

# 연동(C4) 증적
curl -s "http://<ingress-dns>/scenario" | python3 -m json.tool   # upstream_hostname = EC2 hostname

# 모니터링 (가점)
terraform apply -target=module.monitoring -auto-approve   # 메일 구독 확인 링크 클릭(유일한 수동 단계)
```

## 3. 3×4 운영 매트릭스 측정 명령 (요구사항 6 — 1순위)
모든 측정은 `measure.sh`로 감싸 `docs/ops-matrix.csv`에 자동 기록. 복구는 **전/후 캡처** 필수.

| 작업 \ 환경 | VM (EC2 ASG) | Container (EKS) | Serverless (Lambda) |
|---|---|---|---|
| ① 최초 배포 | `terraform apply -target=module.content` → ALB 200까지 | `kubectl apply` → rollout status → Ingress 200까지 | `terraform apply -target=module.note` → 첫 201까지 |
| ② 재배포 (코드 1줄 수정) | `APP_VERSION` 변경 → apply(zip 업로드·LT 새 버전) → (ASG `instance_refresh` 블록이 apply 중 refresh 를 **자동 시작** — 수동 `aws autoscaling start-instance-refresh ...` 는 이미 진행 중이면 오류이므로 생략 가능, T6) → 새 version 응답까지. 무중단 여부 `wait_http` 루프로 관찰 | 이미지 새 태그 → `kubectl -n hermes set image deploy/chat-api chat-api=$ECR:<sha>` → rollout status. 롤링 무중단 | `aws lambda update-function-code --function-name hermes-prd-note-fn --zip-file fileb://note.zip && aws lambda wait function-updated --function-name hermes-prd-note-fn` |
| ③ 강제 종료 복구 (C9) | `aws ec2 terminate-instances --instance-ids <id>` → ASG 재생성 → ALB 200까지 (단일 인스턴스라 다운타임 발생 — 기록) | `kubectl -n hermes delete pod <pod>` → 새 Pod Ready까지 (`kubectl get pods -w`). 다른 replica가 응답 유지 | `POST /notes?crash=1`(실행환경 종료, 502) → 즉시 재요청 201 (CloudWatch 로그 INIT로 새 환경 증명) |
| ④ 용량 2배 | `aws autoscaling set-desired-capacity --auto-scaling-group-name hermes-prd-content-asg --desired-capacity 2` → TG healthy 2개까지 | HPA 있으면 `kubectl -n hermes patch hpa chat-api -p '{"spec":{"minReplicas":4}}'` (없으면 `kubectl scale --replicas=4`) → Ready 4까지 | `aws lambda put-function-concurrency --function-name hermes-prd-note-fn --reserved-concurrent-executions 4` (즉시) |

측정 팁: 시간은 "명령 입력 ~ 외부 URL이 새 상태로 응답"까지로 **정의를 통일**하고 발표 11장에 그 정의를 적는다.

## 4. Day 3 (10/22 ~12:00) — 증적·제출
- [ ] C9 전/후 캡처 2세트(VM, Container) 나란히 배치
- [ ] `docs/ops-matrix.md` 12칸 + 비교 5줄
- [ ] `docs/constraints-check.md` C1~C10
- [ ] 비용(`docs/cost.md`), 회고
- [ ] 발표자료 15장 PDF, 소스 ZIP(`git archive -o hermes.zip HEAD`), README 매핑
- [ ] 12:00 이후 구축 변경 금지, 마감 시점 E2E 동작 유지(C10)

## 5. 정리 (발표 후)
LB Controller가 만든 ALB/SG가 남아 있으면 VPC 삭제가 멈춘다 → **Ingress 먼저 삭제**
```bash
kubectl -n hermes delete ingress chat-api && sleep 60
terraform destroy -auto-approve
aws s3 rb s3://$TFB --force
```
