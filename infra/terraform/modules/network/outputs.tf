output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "[pub-a, pub-c]"
  value       = [aws_subnet.public_a.id, aws_subnet.public_c.id]
}

output "app_subnet_ids" {
  description = "[app-a, app-c]"
  value       = [aws_subnet.app_a.id, aws_subnet.app_c.id]
}

output "data_subnet_ids" {
  description = "[data-a, data-c]"
  value       = [aws_subnet.data_a.id, aws_subnet.data_c.id]
}

output "app_route_table_ids" {
  value = [aws_route_table.app.id]
}

output "ddb_prefix_list_id" {
  description = "Lambda SG egress 443 대상 (DynamoDB 관리형 prefix list)"
  value       = aws_vpc_endpoint.ddb.prefix_list_id
}

output "vpce_ddb_id" {
  description = "DynamoDB 리소스 정책의 aws:SourceVpce 값"
  value       = aws_vpc_endpoint.ddb.id
}
