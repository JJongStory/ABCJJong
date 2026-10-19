resource "aws_ecr_repository" "this" {
  name = var.names.ecr
  # 태그는 git short SHA 로만 찍는다(latest 금지) → 덮어쓰기 방지로 IMMUTABLE
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # PoC 정리(terraform destroy) 시 이미지가 있어도 삭제

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name        = var.names.ecr
    Workload    = "chat"
    ComputeType = "container"
  }
}

# 비용/정리: 최근 20개 이미지만 유지
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}
