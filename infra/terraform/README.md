# infra/terraform — Project HERMES IaC

계약서(`docs/project/01_CONTRACT.md`)의 이름·CIDR·output 을 그대로 구현한다. 이름은 `main.tf` 의 `locals`(한 곳)에서 관리.
의존 순서: **network → data → chat(EKS) → content → note → monitoring**

## 적용 (AWS CloudShell, `03_CLOUDSHELL_RUNBOOK.md` 1~2장과 동일)
```bash
cd ~/hermes/infra/terraform
cp example.tfvars terraform.tfvars && vi terraform.tfvars   # 자동 로드 → runbook 명령에 -var-file 불필요. alert_email, eks_version, bedrock_model_id 확정
terraform init -backend-config="bucket=$TFB" -backend-config="key=hermes/prd.tfstate" -backend-config="region=ap-northeast-2"
terraform validate                                      # 사전 개발 중 provider 6.69.1(미러)로 통과 확인함. CloudShell 에서 한 번 더

V="-auto-approve"
../../scripts/ops/measure.sh shared    deploy         -- terraform apply -target=module.network -target=module.data $V
../../scripts/ops/measure.sh container deploy-cluster -- terraform apply -target=module.chat $V      # 15~20분, 탭 유지!
../../scripts/ops/measure.sh vm        deploy         -- terraform apply -target=module.content $V
../../scripts/ops/measure.sh serverless deploy        -- terraform apply -target=module.note $V
terraform apply -target=module.monitoring $V                                                           # 메일 구독 확인 링크 클릭
terraform apply $V                                      # 마지막에 전체 apply 로 drift 0 확인
```

| 단계 | 대상 | 예상 소요 |
|---|---|---|
| 1 | network + data (NAT, RDS Multi-AZ) | 약 10~15분 (RDS Multi-AZ가 지배) |
| 2 | chat (EKS 컨트롤플레인 + 노드그룹 + 애드온) | 약 15~20분 |
| 3 | content (LT/ASG/ALB 2개, 인스턴스 기동·헬스) | 약 5~8분 |
| 4 | note (Lambda VPC + API GW) | 약 1~3분 |
| 5 | monitoring | 1분 미만 |

LB Controller 는 Terraform 밖(runbook 의 helm 명령)에서 설치한다 — 클러스터 생성 직후 helm provider 인증 의존성을 없애기 위함.
이 모듈은 albc IRSA Role 과 공식 IAM 정책까지만 만든다.

## 설계 메모
- `-target=module.data` 가 EKS 를 끌어오지 않도록 RDS 인바운드 규칙(3306 ← content-ec2-sg)은 **content 모듈**에서 만든다.
- CI(`user17-hermes-shared-gha-role`)는 chat 모듈이 만든다. 출력 `gha_role_arn` 값을 GitHub Repository Variable `AWS_ROLE_ARN` 에 등록 (계정 ID 포함 → 캡처 금지).
- 정리: Ingress 먼저 삭제(`kubectl -n hermes delete ingress chat-api`) 후 `terraform destroy` (runbook 5장).
- 보안 스캔 결과·수용 사유: `SECURITY_SCAN.md`
