variable "alert_email" {
  description = "CloudWatch 알람 SNS 구독 이메일 (구독 확인 메일 클릭은 수동)"
  type        = string
}

variable "admin_role_arns" {
  description = "DynamoDB 데이터 평면 접근을 허용할 관리자 IAM Role/User ARN (CloudShell 실행 주체). 비우면 VPC 엔드포인트 경유만 허용"
  type        = list(string)
  default     = []
}

variable "eks_version" {
  description = "EKS Kubernetes 버전 — 10/20 확정: aws eks describe-cluster-versions 로 최신 standard 확인"
  type        = string
  default     = "1.33" # placeholder: 10/20 확정
}

variable "bedrock_model_id" {
  description = "Claude Haiku 4.5 Global 추론 프로파일 ID — 10/20 확정: aws bedrock list-inference-profiles"
  type        = string
  default     = "global.anthropic.claude-haiku-4-5-20251001-v1:0" # placeholder: 10/20 확정
}

variable "app_version" {
  description = "content-api 버전. 바꾸면 zip 키·User Data 가 바뀌어 Launch Template 새 버전 → instance refresh"
  type        = string
  default     = "v1"
}

variable "content_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "note_reserved_concurrency" {
  description = "note Lambda reserved concurrency (계약서 7장 기본 2). null 이면 미설정 — 신규 계정은 계정 동시성 한도가 낮아 예약이 거부될 수 있음"
  type        = number
  default     = 2
}

variable "github_repo" {
  description = "CI 가 AssumeRole 할 GitHub 저장소 (owner/repo). 계약서 9장"
  type        = string
  default     = "JJongStory/ABCJJong"
}

variable "github_oidc_provider_arn" {
  description = "계정에 GitHub OIDC provider(token.actions.githubusercontent.com)가 이미 있으면 그 ARN. 비우면 새로 생성 (계정당 1개만 허용)"
  type        = string
  default     = ""
}

variable "enable_github_ci_role" {
  description = "hermes-prd-shared-gha-role 생성 여부 (계약서 9장 '선택')"
  type        = bool
  default     = true
}
