output "rds_endpoint" {
  # .address = 호스트명만(포트 없음). .endpoint 는 "host:3306" 이라 앱의 host 설정에 쓰면 깨진다
  description = "RDS 호스트명 (포트 제외)"
  value       = aws_db_instance.this.address
}

output "rds_secret_arn" {
  description = "RDS 관리형 마스터 시크릿 ARN"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "rds_sg_id" {
  description = "content 모듈이 3306 ingress 규칙을 붙일 SG"
  value       = aws_security_group.rds.id
}

output "ddb_table_name" {
  value = aws_dynamodb_table.note.name
}

output "ddb_table_arn" {
  value = aws_dynamodb_table.note.arn
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}
