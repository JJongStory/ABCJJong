# 계약서 11장: 모듈 output 을 같은 이름으로 전부 재노출 (runbook 이 terraform output -raw <이름> 으로 사용)

# network
output "vpc_id" { value = module.network.vpc_id }
output "public_subnet_ids" { value = module.network.public_subnet_ids }
output "app_subnet_ids" { value = module.network.app_subnet_ids }
output "data_subnet_ids" { value = module.network.data_subnet_ids }
output "app_route_table_ids" { value = module.network.app_route_table_ids }
output "ddb_prefix_list_id" { value = module.network.ddb_prefix_list_id }
output "vpce_ddb_id" { value = module.network.vpce_ddb_id }

# data
output "rds_endpoint" { value = module.data.rds_endpoint }
output "rds_secret_arn" { value = module.data.rds_secret_arn }
output "rds_sg_id" { value = module.data.rds_sg_id }
output "ddb_table_name" { value = module.data.ddb_table_name }
output "ddb_table_arn" { value = module.data.ddb_table_arn }
output "artifacts_bucket" { value = module.data.artifacts_bucket }

# chat
output "eks_cluster_name" { value = module.chat.eks_cluster_name }
output "eks_cluster_sg_id" { value = module.chat.eks_cluster_sg_id }
output "oidc_provider_arn" { value = module.chat.oidc_provider_arn }
output "ecr_repo_url" { value = module.chat.ecr_repo_url }
output "chat_irsa_role_arn" { value = module.chat.chat_irsa_role_arn }
output "albc_role_arn" { value = module.chat.albc_role_arn }
output "gha_role_arn" {
  description = "GitHub Actions 변수 AWS_ROLE_ARN 에 등록할 값 (계약서 9장 선택 Role). 캡처 금지"
  value       = module.chat.gha_role_arn
}

# content
output "content_alb_ext_dns" { value = module.content.content_alb_ext_dns }
output "content_alb_int_dns" { value = module.content.content_alb_int_dns }
output "content_ec2_sg_id" { value = module.content.content_ec2_sg_id }
output "content_asg_name" { value = module.content.content_asg_name }

# note
output "note_api_url" { value = module.note.note_api_url }
output "note_fn_name" { value = module.note.note_fn_name }
output "note_api_arn" { value = module.note.note_api_arn }

# monitoring
output "sns_topic_arn" { value = module.monitoring.sns_topic_arn }
