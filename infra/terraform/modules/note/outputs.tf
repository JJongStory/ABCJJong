output "note_api_url" {
  description = "HTTP API invoke URL (trailing slash 없음)"
  value       = trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")
}

output "note_fn_name" {
  value = aws_lambda_function.this.function_name
}

output "note_api_arn" {
  description = "API 실행 ARN (execute-api:Invoke 리소스용)"
  value       = aws_apigatewayv2_api.this.execution_arn
}
