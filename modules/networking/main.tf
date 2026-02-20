################################################################################
# Networking Module - Transit Gateway, VPC, Subnets, Attachment, Routes
################################################################################
#
# Creates:
# - Transit Gateway (TGW)
# - VPC with private subnets (one per AZ)
# - TGW VPC attachment
# - Route table for subnets with 0.0.0.0/0 -> TGW (egress)
#
################################################################################

locals {
  all_vpc_cidrs = concat([var.vpc_cidr], var.vpc_additional_cidrs)
}

# Transit Gateway: regional gateway for routing; this repo creates it.
resource "aws_ec2_transit_gateway" "main" {
  description                     = "Transit Gateway for GitHub runner VPC egress (created by terraform-github-runner-ecs)"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  tags = {
    Name = "${var.name_prefix}-tgw"
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# Lock down default security group (required by CKV2_AWS_12)
# Removes permissive default rules so nothing can accidentally use it.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  ingress = [] # no inbound allowed by default SG
  egress  = [] # no outbound allowed by default SG

  tags = {
    Name = "${var.name_prefix}-default-sg"
  }
}

# CloudWatch Log Group for VPC Flow Logs
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc-flow-logs/${var.name_prefix}"
  retention_in_days = 30

  tags = {
    Name = "${var.name_prefix}-vpc-flow-logs"
  }
}

# IAM role assumed by the VPC Flow Logs service so it can write to CloudWatch Logs
resource "aws_iam_role" "vpc_flow_logs" {
  name = "${var.name_prefix}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.name_prefix}-vpc-flow-logs-role"
  }
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name = "${var.name_prefix}-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
    }]
  })
}

# Enable VPC Flow Logs (required by CKV2_AWS_11)
resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow_logs.arn
  iam_role_arn         = aws_iam_role.vpc_flow_logs.arn

  tags = {
    Name = "${var.name_prefix}-vpc-flow-log"
  }
}

# Optional additional VPC CIDRs (for example a second /16 block).
resource "aws_vpc_ipv4_cidr_block_association" "additional" {
  count = length(var.vpc_additional_cidrs)

  vpc_id     = aws_vpc.main.id
  cidr_block = var.vpc_additional_cidrs[count.index]
}

# One private subnet per AZ; CIDR is derived from VPC CIDR so no overlap.
resource "aws_subnet" "private" {
  count             = length(var.networking_azs)
  vpc_id            = aws_vpc.main.id
  availability_zone = var.networking_azs[count.index]
  cidr_block = cidrsubnet(
    local.all_vpc_cidrs[count.index % length(local.all_vpc_cidrs)],
    4,
    floor(count.index / length(local.all_vpc_cidrs)),
  )
  depends_on = [aws_vpc_ipv4_cidr_block_association.additional]
  tags = {
    Name = "${var.name_prefix}-private-${var.networking_azs[count.index]}"
  }
}

# TGW VPC attachment: attach the VPC to the Transit Gateway.
resource "aws_ec2_transit_gateway_vpc_attachment" "main" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.main.id
  subnet_ids         = aws_subnet.private[*].id
  dns_support        = "enable"
  ipv6_support       = "disable"
  tags = {
    Name = "${var.name_prefix}-tgw-attach"
  }
}

# Route table for the private subnets: send 0.0.0.0/0 to the TGW.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${var.name_prefix}-private-rt"
  }
}

resource "aws_route" "default_via_tgw" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.main.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.main]
}

# Associate the route table with each private subnet.
resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
