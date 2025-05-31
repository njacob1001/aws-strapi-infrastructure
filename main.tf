
# main.tf

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.1.0"
}

provider "aws" {
  region = "us-east-1"
}

#
# 1) VPC y subredes
#
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "vpc-main"
  }
}

# Subredes públicas
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = { Name = "subnet-public-a" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags = { Name = "subnet-public-b" }
}

resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = "us-east-1c"
  map_public_ip_on_launch = true
  tags = { Name = "subnet-public-c" }
}

# Subred privada (para la base de datos)
resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.4.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false
  tags = { Name = "subnet-private" }
}

#
# 2) Internet Gateway + Route Tables
#
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "igw-main" }
}

# Route table para las subredes públicas
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "rtb-public" }
}

# Asociar cada subred pública a la route table pública
resource "aws_route_table_association" "a_association" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "b_association" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "c_association" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public_rt.id
}

# (Opcional: podrías crear aquí una route table privada si necesitaras NAT Gateway)
# En este ejemplo, la subred privada NO tiene acceso a internet (no se crea NAT).

#
# 3) Security Groups
#

# 3.1) SG del Application Load Balancer (permitir HTTP desde internet)
resource "aws_security_group" "sg_alb" {
  name        = "sg-alb"
  description = "Allow HTTP from 0.0.0.0/0"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP desde internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # (Si necesitas HTTPS, agregar puerto 443 aquí)

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-alb" }
}

# 3.2) SG para los EC2 en el Auto Scaling Group (acepta tráfico del ALB en el puerto 80)
resource "aws_security_group" "sg_ec2" {
  name        = "sg-ec2"
  description = "Allow HTTP desde el ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP desde ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_alb.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-ec2" }
}

# 3.3) SG para la base de datos PostgreSQL (acepta sólo desde los EC2)
resource "aws_security_group" "sg_rds" {
  name        = "sg-rds"
  description = "Allow PostgreSQL desde instancias EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL desde EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_ec2.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-rds" }
}

#
# 4) Application Load Balancer + Target Group + Listener
#
resource "aws_lb" "app_lb" {
  name               = "alb-main"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.sg_alb.id]
  subnets            = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id,
    aws_subnet.public_c.id
  ]
  tags = { Name = "app-lb" }
}

# Target Group para EC2 (HTTP:80)
resource "aws_lb_target_group" "tg_ec2" {
  name        = "tg-ec2"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "tg-ec2" }
}

# Listener HTTP que apunta al Target Group
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_ec2.arn
  }
}

#
# 5) Launch Template + Auto Scaling Group
#

# 5.1) Launch Template para las instancias EC2
resource "aws_launch_template" "lt_ec2" {
  name_prefix   = "lt-ec2-"
  image_id      = "ami-0c02fb55956c7d316" # <-- Cambia al AMI que necesites
  instance_type = "t3.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.sg_ec2.id]
  }

  user_data = <<-EOF
              #!/bin/bash
              # Ejemplo de User Data: instalar nginx y servir página de prueba
              apt-get update -y
              apt-get install -y nginx
              systemctl enable nginx
              systemctl start nginx
              echo "<h1>¡Hola desde EC2!</h1>" > /var/www/html/index.html
              EOF

  tag_specifications {
    resource_type = "instance"
    tags = {
      "Name" = "ec2-asg"
    }
  }
}

# 5.2) Auto Scaling Group
resource "aws_autoscaling_group" "asg_ec2" {
  name                      = "asg-ec2"
  max_size                  = 3
  min_size                  = 2
  desired_capacity          = 2
  vpc_zone_identifier       = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id,
    aws_subnet.public_c.id,
  ]
  launch_template {
    id      = aws_launch_template.lt_ec2.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.tg_ec2.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 60

  tags = [
    {
      key                 = "Name"
      value               = "ec2-asg-instance"
      propagate_at_launch = true
    }
  ]

  # Evitar destruir inmediatamente si falla salud; dejar que ASG reemplace
  force_delete = false
}

#
# 6) PostgreSQL en RDS (en subred privada)
#

# Grupo de subredes para RDS (solo incluye la subred privada)
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group"
  subnet_ids = [aws_subnet.private.id]
  tags = {
    Name = "rds-subnet-group"
  }
}

# Instancia RDS PostgreSQL
resource "aws_db_instance" "postgres" {
  identifier              = "postgres-db"
  engine                  = "postgres"
  engine_version          = "13.7"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  storage_type            = "gp2"
  name                    = "mydatabase"
  username                = "admin"
  password                = "TuPasswordSegura123!"  # <-- Cámbiala antes de aplicar
  parameter_group_name    = "default.postgres13"
  db_subnet_group_name    = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids  = [aws_security_group.sg_rds.id]
  skip_final_snapshot     = true
  publicly_accessible     = false
  multi_az                = false

  # Optimiza tiempos de backup si quisieras
  backup_retention_period = 7
  deletion_protection     = false

  tags = {
    Name = "postgres-db"
  }
}

#
# 7) Bucket de S3
#
resource "aws_s3_bucket" "bucket_app" {
  bucket = "mi-bucket-ejemplo-terraform-2025" # <-- Cámbialo a algo único globalmente
  acl    = "private"

  tags = {
    Name        = "bucket-app"
    Environment = "dev"
  }
}

#
# 8) Outputs útiles (opcional)
#
output "vpc_id" {
  description = "ID de la VPC"
  value       = aws_vpc.main.id
}

output "subnet_public_ids" {
  description = "IDs de subredes públicas"
  value       = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id,
    aws_subnet.public_c.id,
  ]
}

output "alb_dns_name" {
  description = "DNS del Application Load Balancer"
  value       = aws_lb.app_lb.dns_name
}

output "rds_endpoint" {
  description = "Endpoint de la base de datos RDS"
  value       = aws_db_instance.postgres.address
}

output "s3_bucket_name" {
  description = "Nombre del bucket de S3"
  value       = aws_s3_bucket.bucket_app.bucket
}
