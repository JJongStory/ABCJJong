variable "names" {
  description = "local.n.note 이름 맵"
  type = object({
    api       = string
    fn        = string
    fn_role   = string
    lambda_sg = string
  })
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "app_subnet_ids" {
  type = list(string)
}

variable "ddb_table_name" {
  type = string
}

variable "ddb_table_arn" {
  type = string
}

variable "ddb_prefix_list_id" {
  type = string
}

variable "reserved_concurrency" {
  description = "null 이면 예약 동시성 미설정"
  type        = number
  default     = 2
  nullable    = true
}

variable "handler" {
  description = "Lambda handler (apps/note-fn/handler.py 의 lambda_handler 가정)"
  type        = string
  default     = "handler.lambda_handler"
}
