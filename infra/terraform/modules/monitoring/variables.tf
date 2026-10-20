variable "names" {
  description = "리소스 이름 맵 (루트 local.n.monitoring)"
  type        = map(string)
}

variable "alert_email" {
  type = string
}

variable "content_alb_ext_arn_suffix" {
  description = "외부 ALB arn_suffix (예: app/name/1234567890abcdef)"
  type        = string
}

variable "content_asg_name" {
  type = string
}

variable "note_fn_name" {
  type = string
}
