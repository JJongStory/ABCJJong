locals {
  tags = {
    Workload    = "content"
    ComputeType = "vm"
  }
  artifact_key = "content/content-api-${var.app_version}.zip"
}

# ---------------------------------------------------------------- Security groups
# 규칙은 별도 리소스로 분리(인라인 금지) — 순환 참조와 규칙 덮어쓰기 방지.
resource "aws_security_group" "alb_ext" {
  name        = var.names.alb_ext_sg
  description = "content external ALB"
  vpc_id      = var.vpc_id
  tags        = { Name = var.names.alb_ext_sg }
}

resource "aws_security_group" "alb_int" {
  name        = var.names.alb_int_sg
  description = "content internal ALB (from EKS pods)"
  vpc_id      = var.vpc_id
  tags        = { Name = var.names.alb_int_sg }
}

resource "aws_security_group" "ec2" {
  name        = var.names.ec2_sg
  description = "content EC2 (no SSH; SSM only)"
  vpc_id      = var.vpc_id
  tags        = { Name = var.names.ec2_sg }
}

# C3 external endpoint exception: the only CIDR-based ingress in the project.
resource "aws_vpc_security_group_ingress_rule" "alb_ext_http" {
  security_group_id = aws_security_group.alb_ext.id
  description       = "C3 external endpoint exception"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
  tags              = merge(local.tags, { Name = "${var.names.alb_ext_sg}-in-80" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_int_http_from_eks" {
  security_group_id            = aws_security_group.alb_int.id
  description                  = "HTTP from EKS cluster SG (pods)"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = var.eks_cluster_sg_id
  tags                         = merge(local.tags, { Name = "${var.names.alb_int_sg}-in-80" })
}

resource "aws_vpc_security_group_egress_rule" "alb_ext_to_ec2" {
  security_group_id            = aws_security_group.alb_ext.id
  description                  = "to content EC2 8080"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.ec2.id
  tags                         = merge(local.tags, { Name = "${var.names.alb_ext_sg}-out-8080" })
}

resource "aws_vpc_security_group_egress_rule" "alb_int_to_ec2" {
  security_group_id            = aws_security_group.alb_int.id
  description                  = "to content EC2 8080"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.ec2.id
  tags                         = merge(local.tags, { Name = "${var.names.alb_int_sg}-out-8080" })
}

resource "aws_vpc_security_group_ingress_rule" "ec2_from_alb_ext" {
  security_group_id            = aws_security_group.ec2.id
  description                  = "app port from external ALB"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb_ext.id
  tags                         = merge(local.tags, { Name = "${var.names.ec2_sg}-in-8080-ext" })
}

resource "aws_vpc_security_group_ingress_rule" "ec2_from_alb_int" {
  security_group_id            = aws_security_group.ec2.id
  description                  = "app port from internal ALB"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb_int.id
  tags                         = merge(local.tags, { Name = "${var.names.ec2_sg}-in-8080-int" })
}

# 443 egress: SSM / Secrets Manager / S3 reach via NAT or endpoints.
# (C8 constrains ingress sources; egress CIDR is acceptable.)
resource "aws_vpc_security_group_egress_rule" "ec2_https" {
  security_group_id = aws_security_group.ec2.id
  description       = "HTTPS to AWS APIs (SSM, Secrets Manager, S3, package repo)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  tags              = merge(local.tags, { Name = "${var.names.ec2_sg}-out-443" })
}

resource "aws_vpc_security_group_egress_rule" "ec2_to_rds" {
  security_group_id            = aws_security_group.ec2.id
  description                  = "MySQL to RDS"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = var.rds_sg_id
  tags                         = merge(local.tags, { Name = "${var.names.ec2_sg}-out-3306" })
}

# RDS ingress is placed here deliberately so `-target=module.data` does not
# depend on the EKS-dependent content SG chain.
resource "aws_vpc_security_group_ingress_rule" "rds_from_ec2" {
  security_group_id            = var.rds_sg_id
  description                  = "MySQL from content EC2"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.ec2.id
  tags                         = merge(local.tags, { Name = "hermes-prd-shared-rds-sg-in-3306-content" })
}

# ---------------------------------------------------------------- IAM
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = var.names.ec2_role
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = merge(local.tags, { Name = var.names.ec2_role })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_inline" {
  statement {
    sid       = "ReadRdsSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.rds_secret_arn]
  }
  statement {
    sid       = "ReadContentArtifacts"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.artifacts_bucket}/content/*"]
  }
}

resource "aws_iam_role_policy" "ec2_inline" {
  name   = "${var.names.ec2_role}-inline"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_inline.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = var.names.instance_profile
  role = aws_iam_role.ec2.name
  tags = merge(local.tags, { Name = var.names.instance_profile })
}

# ---------------------------------------------------------------- App artifact
data "archive_file" "app" {
  type        = "zip"
  source_dir  = "${path.root}/../../apps/content-api"
  output_path = "${path.module}/.build/content-api-${var.app_version}.zip"
  excludes    = ["tests", "__pycache__", ".pytest_cache", "userdata.sh.tftpl"]
}

resource "aws_s3_object" "app" {
  bucket      = var.artifacts_bucket
  key         = local.artifact_key
  source      = data.archive_file.app.output_path
  source_hash = data.archive_file.app.output_md5
  tags        = merge(local.tags, { Name = "${var.names.ec2}-app-${var.app_version}" })
}

# ---------------------------------------------------------------- Launch template / ASG
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_launch_template" "this" {
  name          = var.names.lt
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.content_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  vpc_security_group_ids = [aws_security_group.ec2.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 8
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.root}/../../apps/content-api/userdata.sh.tftpl", {
    DB_HOST       = var.rds_endpoint
    DB_NAME       = var.db_name
    DB_SECRET_ARN = var.rds_secret_arn
    ARTIFACT_URI  = "s3://${var.artifacts_bucket}/${local.artifact_key}"
    APP_VERSION   = var.app_version
    AWS_REGION    = var.region
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = var.names.ec2 })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = var.names.ec2 })
  }

  tags = merge(local.tags, { Name = var.names.lt })

  # zip must exist in S3 before instances boot
  depends_on = [aws_s3_object.app]
}

resource "aws_autoscaling_group" "this" {
  name                      = var.names.asg
  min_size                  = 1
  desired_capacity          = 1
  max_size                  = 2
  vpc_zone_identifier       = var.app_subnet_ids
  health_check_type         = "ELB"
  health_check_grace_period = 120
  target_group_arns         = [aws_lb_target_group.ext.arn, aws_lb_target_group.int.arn]

  launch_template {
    id = aws_launch_template.this.id
    # latest_version (not "$Latest"): value changes with every new LT version,
    # which is what makes the provider start an instance refresh.
    version = aws_launch_template.this.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
    }
  }

  tag {
    key                 = "Name"
    value               = var.names.ec2
    propagate_at_launch = true
  }
  tag {
    key                 = "Workload"
    value               = "content"
    propagate_at_launch = true
  }
  tag {
    key                 = "ComputeType"
    value               = "vm"
    propagate_at_launch = true
  }

  lifecycle {
    # runbook scales desired capacity manually (failure drills)
    ignore_changes = [desired_capacity]
  }
}

# ---------------------------------------------------------------- ALBs / TGs
resource "aws_lb_target_group" "ext" {
  name                 = var.names.tg_ext
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = merge(local.tags, { Name = var.names.tg_ext })
}

resource "aws_lb_target_group" "int" {
  name                 = var.names.tg_int
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = merge(local.tags, { Name = var.names.tg_int })
}

resource "aws_lb" "ext" {
  name                       = var.names.alb_ext
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.alb_ext.id]
  drop_invalid_header_fields = true
  tags                       = merge(local.tags, { Name = var.names.alb_ext })
}

resource "aws_lb" "int" {
  name                       = var.names.alb_int
  load_balancer_type         = "application"
  internal                   = true
  subnets                    = var.app_subnet_ids
  security_groups            = [aws_security_group.alb_int.id]
  drop_invalid_header_fields = true
  tags                       = merge(local.tags, { Name = var.names.alb_int })
}

# HTTP only: PoC without a domain/ACM certificate, so HTTPS listeners are not possible.
resource "aws_lb_listener" "ext" {
  load_balancer_arn = aws_lb.ext.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ext.arn
  }
  tags = merge(local.tags, { Name = "${var.names.alb_ext}-http" })
}

resource "aws_lb_listener" "int" {
  load_balancer_arn = aws_lb.int.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.int.arn
  }
  tags = merge(local.tags, { Name = "${var.names.alb_int}-http" })
}
