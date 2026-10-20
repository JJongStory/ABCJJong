variable "names" {
  description = "리소스 이름 맵 (루트 local.n.data)"
  type        = map(string)
}

variable "vpc_id" {
  type = string
}

variable "data_subnet_ids" {
  type = list(string)
}

variable "vpce_ddb_id" {
  description = "DynamoDB Gateway Endpoint ID (리소스 정책 aws:SourceVpce)"
  type        = string
}

variable "admin_role_arns" {
  description = "DDB 데이터 평면 접근을 허용할 관리자 ARN. 빈 리스트면 엔드포인트 경유만 허용"
  type        = list(string)
  default     = []
}

variable "db_name" {
  type = string
}

variable "db_user" {
  type = string
}

variable "rds_instance_class" {
  type = string
}
