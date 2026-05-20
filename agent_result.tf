
# agent_result.tf
# GPT 기반 실시간 고객 상담 챗봇 AI 서비스 - AWS 인프라
# 월 10만 사용자 기준 | 리전: ap-northeast-2 (서울)

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
  tags = {
    Name        = "chatbot-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.chatbot_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags = {
    Name        = "chatbot-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.chatbot_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2a"
  tags = {
    Name        = "chatbot-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.chatbot_vpc.id
  tags = {
    Name        = "chatbot-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.chatbot_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name        = "chatbot-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_route_table_association" "public_rta" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# ── Security Group ────────────────────────────────────
resource "aws_security_group" "chatbot_sg" {
  name        = "chatbot-sg"
  description = "Security group for GPT chatbot inference server"
  vpc_id      = aws_vpc.chatbot_vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name        = "chatbot-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# ── EC2 GPU 추론 서버 (g5.xlarge / A10G) ──────────────
resource "aws_instance" "chatbot_inference" {
  ami                    = "ami-0c9c942bd7bf113a2"
  instance_type          = "g5.xlarge"
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.chatbot_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.chatbot_profile.name

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    pip install torch transformers fastapi uvicorn
    cd /home/ubuntu
    git clone https://github.com/hyungtakChoi/chatbot-workload-icon.git
    cd chatbot-workload-icon
    nohup uvicorn main:app --host 0.0.0.0 --port 8080 &
  EOF

  tags = {
    Name        = "chatbot-inference-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# ── IAM Role ──────────────────────────────────────────
resource "aws_iam_role" "chatbot_role" {
  name = "chatbot-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_iam_role_policy_attachment" "chatbot_s3" {
  role       = aws_iam_role.chatbot_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_instance_profile" "chatbot_profile" {
  name = "chatbot-instance-profile"
  role = aws_iam_role.chatbot_role.name
}

# ── S3 (모델 아티팩트 저장) ────────────────────────────
resource "aws_s3_bucket" "model_bucket" {
  bucket = "chatbot-gpt-model-artifacts-prod"
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_s3_bucket_versioning" "model_bucket_versioning" {
  bucket = aws_s3_bucket.model_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ── ALB (Application Load Balancer) ──────────────────
resource "aws_lb" "chatbot_alb" {
  name               = "chatbot-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.chatbot_sg.id]
  subnets            = [aws_subnet.public_subnet.id]
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_lb_target_group" "chatbot_tg" {
  name     = "chatbot-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.chatbot_vpc.id
  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_lb_listener" "chatbot_listener" {
  load_balancer_arn = aws_lb.chatbot_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = "arn:aws:acm:ap-northeast-2:ACCOUNT_ID:certificate/CERT_ID"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.chatbot_tg.arn
  }
}

# ── CloudWatch 모니터링 ───────────────────────────────
resource "aws_cloudwatch_metric_alarm" "gpu_utilization" {
  alarm_name          = "chatbot-gpu-high-utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "GPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "GPU utilization exceeded 85%"
  dimensions = {
    InstanceId = aws_instance.chatbot_inference.id
  }
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# ── Outputs ───────────────────────────────────────────
output "alb_dns_name" {
  value       = aws_lb.chatbot_alb.dns_name
  description = "ALB DNS Name for chatbot service"
}

output "inference_instance_id" {
  value       = aws_instance.chatbot_inference.id
  description = "EC2 Inference Server Instance ID"
}

output "model_bucket_name" {
  value       = aws_s3_bucket.model_bucket.bucket
  description = "S3 Bucket for GPT model artifacts"
}
