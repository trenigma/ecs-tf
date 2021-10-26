output "load_balancer_ip" {
  value = aws_lb.ecs_lb.dns_name
}
