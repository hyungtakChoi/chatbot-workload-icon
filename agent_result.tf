
# ============================================================
# AWS Terraform - GPT Chatbot Infra (Seoul / g5.xlarge)
# project=ai-infra | environment=production
# ============================================================

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

# ── VPC ──────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "chatbot-vpc", project = "ai-infra", environment = "production" }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags = { Name = "chatbot-public-a", project = "ai-infra", environment = "production" }
}

resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-northeast-2c"
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
  tags   = { Name = "chatbot-igw", project = "ai-infra", environment = "production" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "chatbot-public-rt", project = "ai-infra", environment = "production" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

# ── Security Groups ───────────────────────────────────────────
resource "aws_security_group" "alb_sg" {
  name   = "chatbot-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 80  to_port = 80  protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 443 to_port = 443 protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0   to_port = 0   protocol = "-1"  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "chatbot-alb-sg", project = "ai-infra", environment = "production" }
}

resource "aws_security_group" "gpu_sg" {
  name   = "chatbot-gpu-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 8080 to_port = 8080 protocol = "tcp" security_groups = [aws_security_group.alb_sg.id] }
  egress  { from_port = 0    to_port = 0    protocol = "-1"  cidr_blocks     = ["0.0.0.0/0"] }
  tags = { Name = "chatbot-gpu-sg", project = "ai-infra", environment = "production" }
}

# ── ALB ──────────────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "chatbot-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_c.id]
  tags = { project = "ai-infra", environment = "production" }
}

resource "aws_lb_target_group" "gpu" {
  name        = "chatbot-gpu-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"
  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = { project = "ai-infra", environment = "production" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gpu.arn
  }
}

# ── Launch Template (g5.xlarge / A10G GPU) ───────────────────
data "aws_ami" "deep_learning" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Deep Learning AMI GPU PyTorch*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_launch_template" "gpu" {
  name_prefix   = "chatbot-gpu-"
  image_id      = data.aws_ami.deep_learning.id
  instance_type = "g5.xlarge"

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.gpu_sg.id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    cd /home/ubuntu
    pip install fastapi uvicorn torch transformers
    nohup uvicorn main:app --host 0.0.0.0 --port 8080 &
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = { Name = "chatbot-gpu-node", project = "ai-infra", environment = "production" }
  }
}

# ── Auto Scaling Group ────────────────────────────────────────
resource "aws_autoscaling_group" "gpu" {
  name                = "chatbot-gpu-asg"
  desired_capacity    = 2
  min_size            = 1
  max_size            = 5
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  target_group_arns   = [aws_lb_target_group.gpu.arn]
  health_check_type   = "ELB"

  launch_template {
    id      = aws_launch_template.gpu.id
    version = "$Latest"
  }

  tag {
    key                 = "project"
    value               = "ai-infra"
    propagate_at_launch = true
  }
  tag {
    key                 = "environment"
    value               = "production"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "chatbot-scale-out"
  autoscaling_group_name = aws_autoscaling_group.gpu.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}

# ── ElastiCache (Redis) - 세션/응답 캐싱 ─────────────────────
resource "aws_elasticache_subnet_group" "redis" {
  name       = "chatbot-redis-subnet"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_c.id]
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "chatbot-redis"
  engine               = "redis"
  node_type            = "cache.t3.medium"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  tags = { project = "ai-infra", environment = "production" }
}

# ── S3 (모델 아티팩트 저장) ───────────────────────────────────
resource "aws_s3_bucket" "model_store" {
  bucket = "chatbot-model-store-ai-infra"
  tags   = { project = "ai-infra", environment = "production" }
}

resource "aws_s3_bucket_versioning" "model_store" {
  bucket = aws_s3_bucket.model_store.id
  versioning_configuration { status = "Enabled" }
}

# ── CloudWatch Alarm ──────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "chatbot-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 75
  alarm_description   = "GPU 인스턴스 CPU 75% 초과 경보"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.gpu.name }
  tags = { project = "ai-infra", environment = "production" }
}

# ── Outputs ───────────────────────────────────────────────────
output "alb_dns_name" {
  description = "ALB DNS (챗봇 엔드포인트)"
  value       = aws_lb.main.dns_name
}

output "redis_endpoint" {
  description = "ElastiCache Redis 엔드포인트"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "model_bucket" {
  description = "S3 모델 저장소"
  value       = aws_s3_bucket.model_store.bucket
}
