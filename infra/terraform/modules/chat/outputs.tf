output "eks_cluster_name" {
  value = aws_eks_cluster.this.name
}

# 노드/Pod 가 공유하는 클러스터 SG — content 모듈의 내부 ALB SG 가 소스로 참조 (계약서 3장)
output "eks_cluster_sg_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "ecr_repo_url" {
  value = aws_ecr_repository.this.repository_url
}

output "chat_irsa_role_arn" {
  value = aws_iam_role.irsa.arn
}

output "albc_role_arn" {
  value = aws_iam_role.albc.arn
}

output "gha_role_arn" {
  description = "CI 역할 ARN (비활성 시 null)"
  value       = try(aws_iam_role.gha[0].arn, null)
}
