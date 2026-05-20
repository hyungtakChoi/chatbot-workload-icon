
# =====================================================
# GPT 기반 실시간 고객 상담 챗봇 AI - AWS Terraform
# CSP: AWS | Region: ap-northeast-2 | g5.xlarge
# Monthly Users: 100,000 | Tags: project=ai-infra
# =====================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

# ── VPC ──────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "chatbot-vpc", project = "ai-infra", environment = "production" }
}

resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags = { Name = "chatbot-public-a", project = "ai-infra", environment = "production" }
}

resource "aws_subnet" "public_c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2c"
  map_public_ip_on_launch = true
  tags = { Name = "chatbot-public-c", project = "ai-infra", environment = "production" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "ap-northeast-2a"
  tags = { Name = "chatbot-private-a", project = "ai-infra", environment = "production" }
}

resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = "ap-northeast-2c"
  tags = { Name = "chatbot-private-c", project = "ai-infra", environment = "production" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "chatbot-igw", project = "ai-infra", environment = "production" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; gateway_id = aws_internet_gateway.igw.id }
  tags = { Name = "chatbot-public-rt", project = "ai-infra", environment = "production" }
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "pub_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

# ── Security Groups ───────────────────────────────────
resource "aws_security_group" "alb_sg" {
  name   = "chatbot-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 80;  to_port = 80;  protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0;   to_port = 0;   protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "chatbot-alb-sg", project = "ai-infra", environment = "production" }
}

resource "aws_security_group" "gpu_sg" {
  name   = "chatbot-gpu-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 8080; to_port = 8080; protocol = "tcp"; security_groups = [aws_security_group.alb_sg.id] }
  egress  { from_port = 0;    to_port = 0;    protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "chatbot-gpu-sg", project = "ai-infra", environment = "production" }
}

# ── ALB ──────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "chatbot-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_c.id]
  tags = { project = "ai-infra", environment = "production" }
}

resource "aws_lb_target_group" "gpu" {
  name     = "chatbot-gpu-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check { path = "/health"; interval = 30; healthy_threshold = 2; unhealthy_threshold = 3 }
  tags = { project = "ai-infra", environment = "production" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action { type = "forward"; target_group_arn = aws_lb_target_group.gpu.arn }
}

# ── Launch Template (g5.xlarge / A10G GPU) ───────────
resource "aws_launch_template" "gpu" {
  name_prefix   = "chatbot-gpu-"
  image_id      = "ami-0c9c942bd7bf113a2"
  instance_type = "g5.xlarge"

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.gpu_sg.id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs { volume_size = 100; volume_type = "gp3"; delete_on_termination = true }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    cd /home/ubuntu
    git clone https://github.com/hyungtakChoi/chatbot-workload-icon.git
    cd chatbot-workload-icon
    pip install -r requirements.txt
    python gpt_inference.py --port 8080
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = { Name = "chatbot-gpu-node", project = "ai-infra", environment = "production" }
  }
}

# ── Auto Scaling Group ────────────────────────────────
resource "aws_autoscaling_group" "gpu" {
  name                = "chatbot-gpu-asg"
  desired_capacity    = 2
  min_size            = 1
  max_size            = 5
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  target_group_arns   = [aws_lb_target_group.gpu.arn]

  launch_template {
    id      = aws_launch_template.gpu.id
    version = "$Latest"
  }

  tag { key = "project"; value = "ai-infra"; propagate_at_launch = true }
  tag { key = "environment"; value = "production"; propagate_at_launch = true }
}

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "chatbot-scale-out"
  autoscaling_group_name = aws_autoscaling_group.gpu.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification { predefined_metric_type = "ASGAverageCPUUtilization" }
    target_value = 70.0
  }
}

# ── ElastiCache (Redis) - 세션/응답 캐싱 ──────────────
resource "aws_elasticache_subnet_group" "redis" {
  name       = "chatbot-redis-subnet"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_c.id]
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "chatbot-redis"
  engine               = "redis"
  node_type            = "cache.t3.medium"
  num_cache_nodes      = 1
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.gpu_sg.id]
  tags = { project = "ai-infra", environment = "production" }
}

# ── S3 (모델 가중치 저장) ─────────────────────────────
resource "aws_s3_bucket" "model" {
  bucket = "chatbot-ai-model-weights-prod"
  tags = { project = "ai-infra", environment = "production" }
}

resource "aws_s3_bucket_versioning" "model" {
  bucket = aws_s3_bucket.model.id
  versioning_configuration { status = "Enabled" }
}

# ── CloudFront (CDN) ──────────────────────────────────
resource "aws_cloudfront_distribution" "cdn" {
  enabled = true
  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "chatbot-alb"
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
    target_origin_id       = "chatbot-alb"
    viewer_protocol_policy = "redirect-to-https"
    forwarded_values {
      query_string = true
      cookies { forward = "none" }
    }
  }
  restrictions { geo_restriction { restriction_type = "none" } }
  viewer_certificate { cloudfront_default_certificate = true }
  tags = { project = "ai-infra", environment = "production" }
}

# ── WAF ───────────────────────────────────────────────
resource "aws_wafv2_web_acl" "main" {
  name  = "chatbot-waf"
  scope = "REGIONAL"
  default_action { allow {} }
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "CommonRuleSet"; sampled_requests_enabled = true }
  }
  visibility_config { cloudwatch_metrics_enabled = true; metric_name = "chatbot-waf"; sampled_requests_enabled = true }
  tags = { project = "ai-infra", environment = "production" }
}

# ── Outputs ───────────────────────────────────────────
output "alb_dns"         { value = aws_lb.main.dns_name }
output "cloudfront_url"  { value = aws_cloudfront_distribution.cdn.domain_name }
output "redis_endpoint"  { value = aws_elasticache_cluster.redis.cache_nodes[0].address }
output "model_s3_bucket" { value = aws_s3_bucket.model.bucket }
