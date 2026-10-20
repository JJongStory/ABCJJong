variable "names" {
  description = "루트 locals.n.chat 의 이름 맵 (계약서 2장)"
  type = object({
    ecr          = string
    eks          = string
    ng           = string
    cluster_role = string
    node_role    = string
    irsa_role    = string
    albc_role    = string
    albc_policy  = string
    gha_role     = string
  })
}

variable "region" {
  description = "배포 리전"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID (현재 직접 사용하지 않음 - 클러스터 SG 는 EKS 가 VPC 안에 자동 생성; 계약 시그니처 유지용)"
  type        = string
}

variable "app_subnet_ids" {
  description = "EKS 컨트롤 플레인 ENI / 노드그룹이 놓일 app(private) 서브넷"
  type        = list(string)
}

variable "eks_version" {
  description = "EKS Kubernetes 버전"
  type        = string
  default     = "1.33" # 10/20 확정
}

variable "bedrock_model_id" {
  description = "Bedrock 모델/추론 프로파일 ID (IRSA 권한 범위 산출에 사용)"
  type        = string
  default     = "global.anthropic.claude-haiku-4-5-20251001-v1:0" # 10/20 확정
}

variable "enable_github_ci_role" {
  description = "GitHub Actions OIDC 역할 생성 여부"
  type        = bool
  default     = true
}

variable "github_repo" {
  description = "owner/repo — CI 역할 trust 의 sub 조건에 사용"
  type        = string
  default     = "JJongStory/ABCJJong"
}

variable "github_oidc_provider_arn" {
  description = "계정에 이미 GitHub OIDC provider 가 있으면 그 ARN. 비우면 새로 생성 (계정당 URL 하나만 허용)"
  type        = string
  default     = ""
}

variable "k8s_namespace" {
  description = "chat-api Pod 네임스페이스 (계약서 6장)"
  type        = string
  default     = "hermes"
}

variable "k8s_service_account" {
  description = "chat-api ServiceAccount 이름"
  type        = string
  default     = "chat-api"
}
