# 사용: cp example.tfvars terraform.tfvars 후 값 수정 (terraform.tfvars 는 자동 로드되고 .gitignore 대상)
# 비밀 값 없음.

alert_email = "your-name@example.com" # SNS 구독 확인 메일을 받을 주소 (유일한 수동 단계)

# CloudShell 실행 주체의 IAM Role/User ARN — DynamoDB 데이터 평면 점검(curl 외 aws dynamodb query 등)용.
# 계정 ID가 들어가므로 이 파일을 커밋하거나 캡처하지 말 것. 비워두면 VPC 엔드포인트 경유만 허용.
admin_role_arns = []

# 10/20 확정 항목
eks_version      = "1.36"                                            # aws eks describe-cluster-versions 로 최신 standard 확인
bedrock_model_id = "global.anthropic.claude-haiku-4-5-20251001-v1:0" # aws bedrock list-inference-profiles 로 확인

app_version               = "v1" # 재배포 측정 시 v2 로 변경 → LT 새 버전 → instance refresh
content_instance_type     = "t3.micro"
rds_instance_class        = "db.t3.micro"
note_reserved_concurrency = 2 # 계정 동시성 한도가 낮으면 거부됨 → null 로 두고 증설 실험 시 CLI 사용

github_repo           = "JJongStory/ABCJJong"
enable_github_ci_role = false # GitHub OIDC provider 는 계정 전역 자원 → 공유 계정에서 충돌·destroy 시 타 사용자 provider 삭제 위험
# 계정에 GitHub OIDC provider 가 이미 있으면(aws iam list-open-id-connect-providers) 그 ARN 을 넣는다
github_oidc_provider_arn = ""
