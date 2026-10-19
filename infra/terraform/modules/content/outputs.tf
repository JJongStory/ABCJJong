output "content_alb_ext_dns" {
  value = aws_lb.ext.dns_name
}

output "content_alb_int_dns" {
  value = aws_lb.int.dns_name
}

output "content_ec2_sg_id" {
  value = aws_security_group.ec2.id
}

output "content_asg_name" {
  value = aws_autoscaling_group.this.name
}

output "content_alb_ext_arn_suffix" {
  description = "모니터링 ALB 5XX 알람 dimension(LoadBalancer)용"
  value       = aws_lb.ext.arn_suffix
}
