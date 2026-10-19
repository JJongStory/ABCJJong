variable "names" {
  description = "local.n.content 이름 맵 (계약서 1장)"
  type = object({
    lt               = string
    asg              = string
    ec2              = string
    alb_ext          = string
    alb_int          = string
    tg_ext           = string
    tg_int           = string
    alb_ext_sg       = string
    alb_int_sg       = string
    ec2_sg           = string
    ec2_role         = string
    instance_profile = string
  })
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "app_subnet_ids" {
  type = list(string)
}

variable "eks_cluster_sg_id" {
  description = "EKS cluster SG ID — 내부 ALB 80 인바운드 소스 (C4)"
  type        = string
}

variable "rds_endpoint" {
  description = "RDS 호스트명 (포트 제외)"
  type        = string
}

variable "rds_secret_arn" {
  type = string
}

variable "rds_sg_id" {
  type = string
}

variable "artifacts_bucket" {
  type = string
}

variable "db_name" {
  type = string
}

variable "app_version" {
  type = string
}

variable "content_instance_type" {
  type    = string
  default = "t3.micro"
}
