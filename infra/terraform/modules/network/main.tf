locals {
  tags = {
    Workload    = "shared"
    ComputeType = "none"
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # EKS/VPC 엔드포인트/SSM 이름 해석에 필요

  tags = merge(local.tags, { Name = var.names["vpc"] })
}

# 기본 SG 의 모든 규칙 제거: 실수로 기본 SG 를 쓰는 리소스가 생겨도 통신 불가 (C8 보강)
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.names["vpc"]}-default-sg-unused" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = var.names["igw"] })
}

# ---- 서브넷: public(ALB/NAT) / app(EC2·EKS·Lambda) / data(RDS, 인터넷 경로 없음) ----
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[0]
  availability_zone       = var.azs[0]
  map_public_ip_on_launch = false # 퍼블릭 IP 는 NAT EIP / ALB 로만 사용

  tags = merge(local.tags, {
    Name                     = var.names["pub_a"]
    "kubernetes.io/role/elb" = "1" # AWS LB Controller 가 외부 ALB 서브넷으로 탐색
  })
}

resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[1]
  availability_zone       = var.azs[1]
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name                     = var.names["pub_c"]
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "app_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.app_subnet_cidrs[0]
  availability_zone = var.azs[0]

  tags = merge(local.tags, {
    Name                              = var.names["app_a"]
    "kubernetes.io/role/internal-elb" = "1" # 내부 ALB(C4) 서브넷 탐색
  })
}

resource "aws_subnet" "app_c" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.app_subnet_cidrs[1]
  availability_zone = var.azs[1]

  tags = merge(local.tags, {
    Name                              = var.names["app_c"]
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_subnet" "data_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.data_subnet_cidrs[0]
  availability_zone = var.azs[0]

  tags = merge(local.tags, { Name = var.names["data_a"] })
}

resource "aws_subnet" "data_c" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.data_subnet_cidrs[1]
  availability_zone = var.azs[1]

  tags = merge(local.tags, { Name = var.names["data_c"] })
}

# ---- NAT: 비용 트레이드오프(ADR-2)로 pub-a 에 1개만. AZ-a 장애 시 app 아웃바운드 중단 감수 ----
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.tags, { Name = var.names["nat_eip"] })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id

  tags = merge(local.tags, { Name = var.names["nat"] })

  depends_on = [aws_internet_gateway.this]
}

# ---- 라우트 테이블 ----
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = var.names["rtb_pub"] })
}

resource "aws_route" "public_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

# app RT 는 두 AZ 가 공유 (NAT 가 1개뿐이라 AZ 별 분리 이점이 없음)
resource "aws_route_table" "app" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = var.names["rtb_app"] })
}

resource "aws_route" "app_nat" {
  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

# data RT 는 라우트 없음(local 만) → RDS 는 인터넷 경로 자체가 없다
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = var.names["rtb_data"] })
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app_a" {
  subnet_id      = aws_subnet.app_a.id
  route_table_id = aws_route_table.app.id
}

resource "aws_route_table_association" "app_c" {
  subnet_id      = aws_subnet.app_c.id
  route_table_id = aws_route_table.app.id
}

resource "aws_route_table_association" "data_a" {
  subnet_id      = aws_subnet.data_a.id
  route_table_id = aws_route_table.data.id
}

resource "aws_route_table_association" "data_c" {
  subnet_id      = aws_subnet.data_c.id
  route_table_id = aws_route_table.data.id
}

# ---- Gateway Endpoint: S3/DynamoDB 트래픽이 NAT 를 우회 (비용 절감 + DDB 정책의 SourceVpce 조건 근거) ----
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.app.id]

  tags = merge(local.tags, { Name = var.names["vpce_s3"] })
}

resource "aws_vpc_endpoint" "ddb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.app.id]

  tags = merge(local.tags, { Name = var.names["vpce_ddb"] })
}
