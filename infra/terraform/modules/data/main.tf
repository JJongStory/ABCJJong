locals {
  tags = {
    Workload    = "shared"
    ComputeType = "none"
  }
}

# ================= RDS MySQL =================
resource "aws_db_subnet_group" "rds" {
  name       = var.names["rds_subnets"]
  subnet_ids = var.data_subnet_ids

  tags = merge(local.tags, { Name = var.names["rds_subnets"] })
}

# 설계 결정: 3306 ingress(content-ec2-sg 소스)는 content 모듈에서 aws_vpc_security_group_ingress_rule 로 만든다.
# 그래야 `-target=module.data` 만 apply 해도 EKS 에 의존하는 content SG 가 딸려오지 않는다.
# 여기서는 ingress/egress 규칙이 없는 빈 SG 만 만든다 (RDS 는 아웃바운드 불필요).
resource "aws_security_group" "rds" {
  name        = var.names["rds_sg"]
  description = "RDS MySQL - ingress 3306 from content-ec2-sg is added by content module"
  vpc_id      = var.vpc_id

  # 인라인 규칙을 쓰지 않아 외부(content) 모듈의 별도 rule 리소스와 충돌하지 않는다
  tags = merge(local.tags, { Name = var.names["rds_sg"] })
}

resource "aws_db_instance" "this" {
  identifier     = var.names["rds"]
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.rds_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  db_name  = var.db_name
  username = var.db_user
  # 비밀번호는 코드에 두지 않는다: RDS 가 Secrets Manager 에 생성·관리 (C 규칙: 평문 크리덴셜 금지)
  manage_master_user_password = true

  multi_az               = true # C5/RFP: 고가용성
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  backup_retention_period = 1
  # PoC 라 destroy 시 깔끔히 지워지도록 함. 운영이라면 deletion_protection=true, final snapshot 필수
  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true

  tags = merge(local.tags, { Name = var.names["rds"] })
}

# ================= DynamoDB =================
resource "aws_dynamodb_table" "note" {
  name         = var.names["ddb"]
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "created_at"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  server_side_encryption {
    enabled = true # kms_key_arn 생략 → AWS 소유 키(추가 비용 없음)
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name        = var.names["ddb"]
    Workload    = "note"
    ComputeType = "serverless"
  }
}

# 데이터 평면만 Deny: VPC 엔드포인트 경유가 아니고 관리자 Role 도 아니면 거부.
# 제어 평면(DescribeTable, PutResourcePolicy 등)은 일부러 Deny 하지 않는다 → terraform 이 스스로 잠기는 일 방지.
# Lambda 는 Gateway Endpoint 로 접근하므로 SourceVpce 가 일치한다.
resource "aws_dynamodb_resource_policy" "note" {
  resource_arn = aws_dynamodb_table.note.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyDataPlaneOutsideVpceAndAdmin"
      Effect    = "Deny"
      Principal = "*"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:BatchGetItem",
        "dynamodb:BatchWriteItem",
      ]
      Resource = [
        aws_dynamodb_table.note.arn,
        "${aws_dynamodb_table.note.arn}/index/*",
      ]
      # admin_role_arns 가 비면 ArnNotLike 조건을 통째로 생략 (빈 배열은 정책 오류)
      Condition = merge(
        { StringNotEquals = { "aws:SourceVpce" = var.vpce_ddb_id } },
        length(var.admin_role_arns) > 0 ? { ArnNotLike = { "aws:PrincipalArn" = var.admin_role_arns } } : {}
      )
    }]
  })
}

# ================= Artifacts S3 =================
# 버킷명 전역 유일성 확보용 랜덤 접미사 (계정 ID 노출 방지, 6 hex)
resource "random_id" "suffix" {
  byte_length = 3
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.names["artifacts_prefix"]}-${random_id.suffix.hex}"
  force_destroy = true # PoC 정리 편의: 객체가 있어도 destroy 가능

  tags = merge(local.tags, { Name = "${var.names["artifacts_prefix"]}-${random_id.suffix.hex}" })
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.artifacts.arn,
        "${aws_s3_bucket.artifacts.arn}/*",
      ]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  # public access block 과 정책을 동시에 쓰면 충돌할 수 있어 순서 고정
  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}
