variable "names" {
  description = "리소스 Name 태그 맵 (루트 local.n.network)"
  type        = map(string)
}

variable "azs" {
  description = "사용할 AZ 2개 (a, c 순서)"
  type        = list(string)
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "app_subnet_cidrs" {
  type = list(string)
}

variable "data_subnet_cidrs" {
  type = list(string)
}
