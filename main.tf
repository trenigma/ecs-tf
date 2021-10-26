data "aws_availability_zones" "available_zones" {
  state = "available"
}

# VPC 
resource "aws_vpc" "ecs_tf" {
  cidr_block = "10.32.0.0/16"

  tags = {
    Name = "ecs-tf"
  }
}

# subnets
resource "aws_subnet" "public" {
  count                   = 3
  cidr_block              = cidrsubnet(aws_vpc.ecs_tf.cidr_block, 8, 3 + count.index)
  availability_zone       = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id                  = aws_vpc.ecs_tf.id
  map_public_ip_on_launch = true

  tags = {
    Name = "ecs-tf-public-${count.index + 1}"
  }
}

resource "aws_subnet" "private" {
  count             = 3
  cidr_block        = cidrsubnet(aws_vpc.ecs_tf.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id            = aws_vpc.ecs_tf.id

  tags = {
    Name = "ecs-tf-private-${count.index + 1}"
  }
}

# routing
resource "aws_internet_gateway" "gateway" {
  vpc_id = aws_vpc.ecs_tf.id

  tags = {
    Name = "ecs-tf-igw"
  }
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.ecs_tf.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gateway.id
}

resource "aws_eip" "gateway" {
  count      = 3
  vpc        = true
  depends_on = [aws_internet_gateway.gateway]

  tags = {
    Name = "ecs-tf-eip"
  }
}

resource "aws_nat_gateway" "gateway" {
  count         = 3
  subnet_id     = element(aws_subnet.public.*.id, count.index)
  allocation_id = element(aws_eip.gateway.*.id, count.index)

  tags = {
    Name = "ecs-tf-nat-gw-${count.index + 1}"
  }
}

resource "aws_route_table" "private" {
  count  = 3
  vpc_id = aws_vpc.ecs_tf.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.gateway.*.id, count.index)
  }

  tags = {
    Name = "ecs-tf-route-table-private-${count.index + 1}"
  }
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}

# ALB security group
resource "aws_security_group" "lb" {
  name   = "ecs-alb-security-group"
  vpc_id = aws_vpc.ecs_tf.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0 # any port
    to_port     = 0
    protocol    = "-1" # any protocol
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ecs-lb-sg"
  }
}

# ALB 
resource "aws_lb" "ecs_lb" {
  name            = "ecs-lb"
  subnets         = aws_subnet.public.*.id
  security_groups = [aws_security_group.lb.id]

  tags = {
    Name = "ecs-tf-alb"
  }
}

resource "aws_lb_target_group" "hello_world" {
  name        = "ecs-tf-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.ecs_tf.id
  target_type = "ip"

  tags = {
    Name = "ecs-tf-alb-target-group"
  }
}

resource "aws_lb_listener" "hello_world" {
  load_balancer_arn = aws_lb.ecs_lb.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.hello_world.id
    type             = "forward"
  }
  tags = {
    Name = "ecs-tf-alb-listener"
  }
}

# ECS task definition
resource "aws_ecs_task_definition" "hello_world" {
  family                   = "hello-world-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048

  container_definitions = <<DEFINITION
[
  {
    "image": "heroku/nodejs-hello-world",
    "cpu": 1024,
    "memory": 2048,
    "name": "hello-world-app",
    "networkMode": "awsvpc",
    "portMappings": [
      {
        "containerPort": 3000,
        "hostPort": 3000
      }
    ]
  }
]
DEFINITION

  tags = {
    Name = "ecs-tf-task-definition"
  }
}

resource "aws_security_group" "hello_world_task" {
  name   = "ecs-tf-security-group"
  vpc_id = aws_vpc.ecs_tf.id

  ingress {
    protocol        = "tcp"
    from_port       = 3000
    to_port         = 3000
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ecs-task-hello-world-sg"
  }
}

# ECS service
resource "aws_ecs_cluster" "main" {
  name = "ecs-tf"
}

resource "aws_ecs_service" "hello_world" {
  name            = "hello-world-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.hello_world.arn
  desired_count   = var.app_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.hello_world_task.id]
    subnets         = aws_subnet.private.*.id
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.hello_world.id
    container_name   = "hello-world-app"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener.hello_world]

  tags = {
    Name = "ecs-service-hello-world"
  }
}





