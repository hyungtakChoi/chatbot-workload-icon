
# =====================================================
# 실시간 고객 상담 챗봇 AI - AWS Terraform 코드
# CSP: AWS | Region: ap-northeast-2 (서울)
# 월 10만 사용자 기준 | 예상 비용: ~$290/월
# =====================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

# ── VPC ──────────────────────────────────────────────
resource "aws_vpc" "chatbot_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "chatbot-vpc", project = "ai-infra", environment = "production" }
}

resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.chatbot_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags = { Name = "chatbot-public-a", project = "ai-infra", environment = "production" }
}

resource "aws_subnet" "public_c" {
  vpc_id            = aws_vpc.chatbot_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2c"
  map_public_ip_on_launch = true
  tags = { Name = "chatbot-public-c", project = "ai-infra", environment = "production" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.chatbot_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "ap-northeast-2a"
  tags = { Name = "chatbot-private-a", project = "ai-infra", environment = "production" }
}

resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.chatbot_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "ap-northeast-2c"
  tags = { Name = "chatbot-private-c", project = "ai-infra", environment = "production" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.chatbot_vpc.id
  tags = { Name = "chatbot-igw", project = "ai-infra", environment = "production" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.chatbot_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "chatbot-public-rt", project = "ai-infra", environment = "production" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public_rt.id
}

# ── Security Groups ───────────────────────────────────
resource "aws_security_group" "alb_sg" {
  name   = "chatbot-alb-sg"
  vpc_id = aws_vpc.chatbot_vpc.id
  ingress { from_port = 80  to_port = 80  protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 443 to_port = 443 protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0   to_port = 0   protocol = "-1"  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "chatbot-alb-sg", project = "ai-infra", environment = "production" }
}

resource "aws_security_group" "app_sg" {
  name   = "chatbot-app-sg"
  vpc_id = aws_vpc.chatbot_vpc.id
  ingress { from_port = 8080 to_port = 8080 protocol = "tcp" security_groups = [aws_security_group.alb_sg.id] }
  egress  { from_port = 0    to_port = 0    protocol = "-1"  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "chatbot-app-sg", project = "ai-infra", environment = "production" }
}

resource "aws_security_group" "gpu_sg" {
  name   = "chatbot-gpu-sg"
  vpc_id = aws_vpc.chatbot_vpc.id
  ingress { from_port = 5000 to_port = 5000 protocol = "tcp" security_groups = [aws_security_group.app_sg.id] }
  egress  { from_port = 0    to_port = 0    protocol = "-1"  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "chatbot-gpu-sg", project = "ai-infra", environment = "production" }
}

resource "aws_security_group" "redis_sg" {
  name   = "chatbot-redis-sg"
  vpc_id = aws_vpc.chatbot_vpc.id
  ingress { from_port = 6379 to_port = 6379 protocol = "tcp" security_groups = [aws_security_group.app_sg.id] }
  egress  { from_port = 0    to_port = 0    protocol = "-1"  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "chatbot-redis-sg", project = "ai-infra", environment = "production" }
}

resource "aws_security_group" "rds_sg" {
  name   = "chatbot-rds-sg"
  vpc_id = aws_vpc.chatbot_vpc.id
  ingress { from_port = 5432 to_port = 5432 protocol = "tcp" security_groups = [aws_security_group.app_sg.id] }
  egress  { from_port = 0    to_port = 0    protocol = "-1"  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "chatbot-rds-sg", project = "ai-infra", environment = "production" }
}

# ── ALB ──────────────────────────────────────────────
resource "aws_lb" "chatbot_alb" {
  name               = "chatbot-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_c.id]
  tags = { project = "ai-infra", environment = "production" }
}

resource "aws_lb_target_group" "app_tg" {
  name     = "chatbot-app-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.chatbot_vpc.id
  health_check { path = "/health" interval = 30 healthy_threshold = 2 unhealthy_threshold = 3 }
  tags = { project = "ai-infra", environment = "production" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.chatbot_alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action { type = "forward" target_group_arn = aws_lb_target_group.app_tg.arn }
}

# ── App Server (Auto Scaling) ─────────────────────────
resource "aws_launch_template" "app_lt" {
  name_prefix   = "chatbot-app-"
  image_id      = "ami-0c9c942bd7bf113a2"
  instance_type = "t3.medium"
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  tag_specifications {
    resource_type = "instance"
    tags = { Name = "chatbot-app", project = "ai-infra", environment = "production" }
  }
  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y python3 python3-pip
    pip3 install fastapi uvicorn redis psycopg2-binary
    EOF
  )
}

resource "aws_autoscaling_group" "app_asg" {
  name                = "chatbot-app-asg"
  min_size            = 1
  max_size            = 5
  desired_capacity    = 2
  vpc_zone_identifier = [aws_subnet.public_a.id, aws_subnet.public_c.id]
  target_group_arns   = [aws_lb_target_group.app_tg.arn]
  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }
  tag { key = "project" value = "ai-infra" propagate_at_launch = true }
  tag { key = "environment" value = "production" propagate_at_launch = true }
}

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "chatbot-scale-out"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification { predefined_metric_type = "ASGAverageCPUUtilization" }
    target_value = 60.0
  }
}

# ── GPU Spot Instance (Inference Server) ──────────────
resource "aws_spot_instance_request" "gpu_inference" {
  ami                    = "ami-0c9c942bd7bf113a2"
  instance_type          = "g4dn.xlarge"
  spot_price             = "0.30"
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.gpu_sg.id]
  wait_for_fulfillment   = true
  tags = { Name = "chatbot-gpu-inference", project = "ai-infra", environment = "production" }
  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y python3 python3-pip
    pip3 install torch transformers fastapi uvicorn
    EOF
  )
}

# ── ElastiCache Redis ─────────────────────────────────
resource "aws_elasticache_subnet_group" "redis_subnet" {
  name       = "chatbot-redis-subnet"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_c.id]
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "chatbot-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis_subnet.name
  security_group_ids   = [aws_security_group.redis_sg.id]
  tags = { project = "ai-infra", environment = "production" }
}

# ── RDS PostgreSQL ────────────────────────────────────
resource "aws_db_subnet_group" "rds_subnet" {
  name       = "chatbot-rds-subnet"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  tags = { project = "ai-infra", environment = "production" }
}

resource "aws_db_instance" "postgres" {
  identifier           = "chatbot-postgres"
  engine               = "postgres"
  engine_version       = "15.4"
  instance_class       = "db.t3.micro"
  allocated_storage    = 20
  db_name              = "chatbot_db"
  username             = "chatbot_admin"
  password             = "ChangeMe!2024"
  db_subnet_group_name = aws_db_subnet_group.rds_subnet.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot  = true
  tags = { project = "ai-infra", environment = "production" }
}

# ── CloudFront ────────────────────────────────────────
resource "aws_cloudfront_distribution" "chatbot_cdn" {
  enabled = true
  origin {
    domain_name = aws_lb.chatbot_alb.dns_name
    origin_id   = "chatbot-alb-origin"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
  default_cache_behavior {
    allowed_methods        = ["DELETE","GET","HEAD","OPTIONS","PATCH","POST","PUT"]
    cached_methods         = ["GET","HEAD"]
    target_origin_id       = "chatbot-alb-origin"
    viewer_protocol_policy = "redirect-to-https"
    forwarded_values {
      query_string = true
      cookies { forward = "none" }
    }
    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }
  restrictions { geo_restriction { restriction_type = "none" } }
  viewer_certificate { cloudfront_default_certificate = true }
  tags = { project = "ai-infra", environment = "production" }
}

# ── Outputs ───────────────────────────────────────────
output "alb_dns"         { value = aws_lb.chatbot_alb.dns_name }
output "cloudfront_url"  { value = aws_cloudfront_distribution.chatbot_cdn.domain_name }
output "redis_endpoint"  { value = aws_elasticache_cluster.redis.cache_nodes[0].address }
output "rds_endpoint"    { value = aws_db_instance.postgres.endpoint }
output "gpu_instance_id" { value = aws_spot_instance_request.gpu_inference.spot_instance_id }
