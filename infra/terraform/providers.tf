terraform {
  required_version = ">= 1.10"

  required_providers {
    # 계약서 1장: AWS provider ~> 6.x. 모든 모듈이 같은 메이저를 쓴다.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = local.region

  # 계약서 1장 필수 태그. 리소스별 Workload/ComputeType 태그는 각 모듈에서 추가.
  default_tags {
    tags = {
      Project   = "HERMES"
      Owner     = "parkjongho"
      Env       = "prd"
      ManagedBy = "terraform"
    }
  }
}
