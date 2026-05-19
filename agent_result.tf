
# ============================================================
# Terraform Code - 실시간 고객 상담 챗봇 AI 서비스
# CSP     : AWS (ap-northeast-2, 서울)
# Instance: g5.xlarge (A10G GPU 1x, 16GB RAM)
# Users   : 월 10만 사용자
# Tags    : project=ai-infra, environment=production
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
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name        = "chatbot-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# ── Subnets ───────────────────────────────────────────────────
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

# ── Internet Gateway & NAT ────────────────────────────────────
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "chatbot-igw", project = "ai-infra", environment = "production" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "chatbot-nat-eip", project = "ai-infra", environment = "production" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  tags          = { Name = "chatbot-nat", project = "ai-infra", environment = "production" }
}

# ── Route Tables ──────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "chatbot-rt-public", project = "ai-infra", environment = "production" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "chatbot-rt-private", project = "ai-infra", environment = "production" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private.id
}

# ── Security Groups ───────────────────────────────────────────
resource "aws_security_group" "alb_sg" {
  name   = "chatbot-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "chatbot-alb-sg", project = "ai-infra", environment = "production" }
}

resource "aws_security_group" "app_sg" {
  name   = "chatbot-app-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "chatbot-app-sg", project = "ai-infra", environment = "production" }
}

resource "aws_security_group" "gpu_sg" {
  name   = "chatbot-gpu-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "chatbot-gpu-sg", project = "ai-infra", environment = "production" }
}

# ── ALB ───────────────────────────────────────────────────────
resource "aws_lb" "alb" {
  name               = "chatbot-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_c.id]
  tags               = { project = "ai-infra", environment = "production" }
}

resource "aws_lb_target_group" "app_tg" {
  name        = "chatbot-app-tg"
  port        = 8000
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
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# ── ECS Cluster (API 서버) ────────────────────────────────────
resource "aws_ecs_cluster" "chatbot" {
  name = "chatbot-cluster"
  tags = { project = "ai-infra", environment = "production" }
}

resource "aws_iam_role" "ecs_task_exec" {
  name = "chatbot-ecs-task-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { project = "ai-infra", environment = "production" }
}

resource "aws_iam_role_policy_attachment" "ecs_exec_policy" {
  role       = aws_iam_role.ecs_task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "chatbot_api" {
  family                   = "chatbot-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_exec.arn
  container_definitions = jsonencode([{
    name      = "chatbot-api"
    image     = "chatbot-api:latest"
    essential = true
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]
    environment = [
      { name = "GPU_INFERENCE_ENDPOINT", value = "http://${aws_instance.gpu_inference.private_ip}:8080" },
      { name = "REDIS_HOST",             value = aws_elasticache_cluster.session.cache_nodes[0].address }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/chatbot-api"
        "awslogs-region"        = "ap-northeast-2"
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
  tags = { project = "ai-infra", environment = "production" }
}

resource "aws_ecs_service" "chatbot_api" {
  name            = "chatbot-api-service"
  cluster         = aws_ecs_cluster.chatbot.id
  task_definition = aws_ecs_task_definition.chatbot_api.arn
  desired_count   = 2
  launch_type     = "FARGATE"
  network_configuration {
    subnets         = [aws_subnet.private_a.id, aws_subnet.private_c.id]
    security_groups = [aws_security_group.app_sg.id]
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "chatbot-api"
    container_port   = 8000
  }
  tags = { project = "ai-infra", environment = "production" }
}

# ── GPU 추론 서버 (g5.xlarge) ─────────────────────────────────
data "aws_ami" "gpu_ami" {
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

resource "aws_instance" "gpu_inference" {
  ami                    = data.aws_ami.gpu_ami.id
  instance_type          = "g5.xlarge"
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.gpu_sg.id]
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }
  user_data = <<-EOF
    #!/bin/bash
    pip install torch transformers fastapi uvicorn
    cd /home/ubuntu && python gpt_inference.py &
  EOF
  tags = {
    Name        = "chatbot-gpu-inference"
    project     = "ai-infra"
    environment = "production"
  }
}

# ── ElastiCache (Redis) - 세션/캐시 ──────────────────────────
resource "aws_elasticache_subnet_group" "redis_subnet" {
  name       = "chatbot-redis-subnet"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  tags       = { project = "ai-infra", environment = "production" }
}

resource "aws_elasticache_cluster" "session" {
  cluster_id           = "chatbot-redis"
  engine               = "redis"
  node_type            = "cache.t3.medium"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  subnet_group_name    = aws_elasticache_subnet_group.redis_subnet.name
  security_group_ids   = [aws_security_group.app_sg.id]
  tags                 = { project = "ai-infra", environment = "production" }
}

# ── CloudWatch Logs ───────────────────────────────────────────
resource "aws_cloudwatch_log_group" "ecs_api" {
  name              = "/ecs/chatbot-api"
  retention_in_days = 30
  tags              = { project = "ai-infra", environment = "production" }
}

resource "aws_cloudwatch_metric_alarm" "gpu_cpu_high" {
  alarm_name          = "chatbot-gpu-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "GPU 인스턴스 CPU 사용률 80% 초과"
  dimensions          = { InstanceId = aws_instance.gpu_inference.id }
  tags                = { project = "ai-infra", environment = "production" }
}

# ── Outputs ───────────────────────────────────────────────────
output "alb_dns_name" {
  description = "ALB DNS (챗봇 API 엔드포인트)"
  value       = aws_lb.alb.dns_name
}

output "gpu_instance_private_ip" {
  description = "GPU 추론 서버 Private IP"
  value       = aws_instance.gpu_inference.private_ip
}

output "redis_endpoint" {
  description = "Redis 세션 캐시 엔드포인트"
  value       = aws_elasticache_cluster.session.cache_nodes[0].address
}
