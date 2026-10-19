data "aws_caller_identity" "current" {}

locals {
  tags = {
    Workload    = "shared"
    ComputeType = "none"
  }
}

resource "aws_sns_topic" "alerts" {
  name = var.names["sns"]
  # KMS 암호화 없음: CloudWatch 알람은 AWS 관리형 키(alias/aws/sns)로 암호화된 토픽에 Publish 할 수 없다
  # (키 정책을 수정할 수 없음). 고객관리형 키는 PoC 범위 초과 → 알람 알림 수신(가점 증적)을 우선. trivy 지적은 SECURITY_SCAN.md 에 수용 기록.

  tags = merge(local.tags, { Name = var.names["sns"] })
}

# CloudWatch 알람만 같은 계정 범위에서 Publish 허용 (confused deputy 방지: SourceAccount)
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchAlarmsPublish"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

# 이메일 구독은 수신자가 확인 메일을 수동 클릭해야 활성화됨
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# (1) 외부 ALB 가 직접 만든 5xx — 1건이라도 나면 알림
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = var.names["alarm_alb_5xx"]
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = var.content_alb_ext_arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching" # 트래픽 없으면 데이터 없음 → 정상 취급
  alarm_actions       = [aws_sns_topic.alerts.arn]

  tags = merge(local.tags, { Name = var.names["alarm_alb_5xx"] })
}

# (2) ASG 평균 CPU 70% 초과가 2분 지속
resource "aws_cloudwatch_metric_alarm" "asg_cpu" {
  alarm_name          = var.names["alarm_asg_cpu"]
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { AutoScalingGroupName = var.content_asg_name }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 70
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  tags = merge(local.tags, { Name = var.names["alarm_asg_cpu"] })
}

# (3) note Lambda 에러 1건 이상
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = var.names["alarm_lambda_errs"]
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.note_fn_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  tags = merge(local.tags, { Name = var.names["alarm_lambda_errs"] })
}
