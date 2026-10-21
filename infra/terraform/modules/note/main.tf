locals {
  tags = {
    Workload    = "note"
    ComputeType = "serverless"
  }
}

data "archive_file" "fn" {
  type        = "zip"
  source_dir  = "${path.root}/../../apps/note-fn"
  output_path = "${path.module}/.build/note-fn.zip"
  excludes    = ["tests", "__pycache__", ".pytest_cache"]
}

# ---------------------------------------------------------------- IAM
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fn" {
  name               = var.names.fn_role
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = merge(local.tags, { Name = var.names.fn_role })
}

resource "aws_iam_role_policy_attachment" "vpc" {
  role       = aws_iam_role.fn.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "ddb" {
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:Query"]
    resources = [var.ddb_table_arn]
  }
}

resource "aws_iam_role_policy" "ddb" {
  name   = "${var.names.fn_role}-ddb"
  role   = aws_iam_role.fn.id
  policy = data.aws_iam_policy_document.ddb.json
}

# ---------------------------------------------------------------- Network
resource "aws_security_group" "lambda" {
  name        = var.names.lambda_sg
  description = "note Lambda (no ingress)"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = var.names.lambda_sg })
}

# Only DynamoDB via the gateway endpoint prefix list; no NAT/internet needed.
resource "aws_vpc_security_group_egress_rule" "ddb" {
  security_group_id = aws_security_group.lambda.id
  description       = "HTTPS to DynamoDB gateway endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = var.ddb_prefix_list_id
  tags              = merge(local.tags, { Name = "${var.names.lambda_sg}-out-443-ddb" })
}

# ---------------------------------------------------------------- Lambda
resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/${var.names.fn}"
  retention_in_days = 7
  tags              = merge(local.tags, { Name = "/aws/lambda/${var.names.fn}" })
}

resource "aws_lambda_function" "this" {
  function_name = var.names.fn
  role          = aws_iam_role.fn.arn
  runtime       = "python3.12"
  handler       = var.handler
  memory_size   = 128
  timeout       = 10

  filename         = data.archive_file.fn.output_path
  source_code_hash = data.archive_file.fn.output_base64sha256

  reserved_concurrent_executions = var.reserved_concurrency

  vpc_config {
    subnet_ids         = var.app_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      TABLE_NAME = var.ddb_table_name
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.fn.name
  }

  tags = merge(local.tags, { Name = var.names.fn })

  depends_on = [
    aws_cloudwatch_log_group.fn,
    aws_iam_role_policy_attachment.vpc,
    aws_iam_role_policy.ddb,
    aws_vpc_security_group_egress_rule.ddb,
  ]
}

# ---------------------------------------------------------------- API Gateway (HTTP API)
resource "aws_apigatewayv2_api" "this" {
  name          = var.names.api
  protocol_type = "HTTP"
  tags          = merge(local.tags, { Name = var.names.api })
}

resource "aws_apigatewayv2_integration" "fn" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.this.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_notes" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /notes"
  target    = "integrations/${aws_apigatewayv2_integration.fn.id}"
}

resource "aws_apigatewayv2_route" "get_notes" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /notes/{user_id}"
  target    = "integrations/${aws_apigatewayv2_integration.fn.id}"
}

# 학습자 대화 저장/조회 (닉네임 = user_id). 같은 함수·같은 테이블(SK 접두사 conv#)
resource "aws_apigatewayv2_route" "post_conversations" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /conversations"
  target    = "integrations/${aws_apigatewayv2_integration.fn.id}"
}

resource "aws_apigatewayv2_route" "get_conversations" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /conversations/{user_id}"
  target    = "integrations/${aws_apigatewayv2_integration.fn.id}"
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${var.names.api}"
  retention_in_days = 7
  tags              = merge(local.tags, { Name = "/aws/apigateway/${var.names.api}" })
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      httpMethod              = "$context.httpMethod"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }

  tags = merge(local.tags, { Name = "${var.names.api}-default" })
}

# Scoped to this API only (any stage/route) rather than all of API Gateway.
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowInvokeFromNoteApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
