################################################################################
# Networking Module - VPC, Public/Private Subnets, NAT Gateway, IGW, Routes
################################################################################
#
# Creates:
# - VPC with private subnets (one per AZ, for ECS) and public subnets (one per AZ, for NAT)
# - Internet Gateway (IGW) attached to VPC
# - NAT gateway per AZ in public subnet (egress for private subnets)
# - Public route table: 0.0.0.0/0 -> IGW
# - Private route table per AZ: 0.0.0.0/0 -> NAT gateway (that AZ)
#
# Egress path: ECS -> private subnet route table -> NAT gateway -> IGW -> internet
#
################################################################################

locals {
  all_vpc_cidrs = concat([var.vpc_cidr], var.vpc_additional_cidrs)
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# Internet Gateway for NAT gateway egress to the internet
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${var.name_prefix}-igw"
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

resource "aws_kms_key" "vpc_flow_logs" {
  description             = "KMS key for CloudWatch log group encryption: VPC flow logs (${var.name_prefix})"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountAdmin"
        Effect = "Allow"
        Principal = {
          AWS = format("arn:aws:iam::%s:root", data.aws_caller_identity.current.account_id)
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogsUse"
        Effect = "Allow"
        Principal = {
          Service = format("logs.%s.amazonaws.com", data.aws_region.current.name)
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${var.name_prefix}-vpc-flow-logs-kms"
  }
}

resource "aws_kms_alias" "vpc_flow_logs" {
  name          = "alias/${var.name_prefix}-vpc-flow-logs"
  target_key_id = aws_kms_key.vpc_flow_logs.key_id
}

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc-flow-logs/${var.name_prefix}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.vpc_flow_logs.arn

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

# One public subnet per AZ (for NAT gateway placement); CIDR distinct from private.
resource "aws_subnet" "public" {
  count             = length(var.networking_azs)
  vpc_id            = aws_vpc.main.id
  availability_zone = var.networking_azs[count.index]
  cidr_block = cidrsubnet(
    local.all_vpc_cidrs[count.index % length(local.all_vpc_cidrs)],
    4,
    length(var.networking_azs) + count.index,
  )
  depends_on = [aws_vpc_ipv4_cidr_block_association.additional]
  map_public_ip_on_launch = true
  tags = {
    Name = "${var.name_prefix}-public-${var.networking_azs[count.index]}"
  }
}

# Public route table: 0.0.0.0/0 -> IGW (so NAT gateway can reach internet)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Elastic IP per AZ for NAT gateway
resource "aws_eip" "nat" {
  count  = length(var.networking_azs)
  domain = "vpc"
  tags = {
    Name = "${var.name_prefix}-nat-eip-${var.networking_azs[count.index]}"
  }
  depends_on = [aws_internet_gateway.main]
}

# NAT gateway per AZ (in public subnet) for private subnet egress
resource "aws_nat_gateway" "main" {
  count         = length(var.networking_azs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags = {
    Name = "${var.name_prefix}-nat-${var.networking_azs[count.index]}"
  }
  depends_on = [aws_route_table_association.public]
}

# Private route table per AZ: 0.0.0.0/0 -> this AZ's NAT gateway
resource "aws_route_table" "private" {
  count  = length(var.networking_azs)
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${var.name_prefix}-private-rt-${var.networking_azs[count.index]}"
  }
}

resource "aws_route" "private_default" {
  count                   = length(var.networking_azs)
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[count.index].id
}

# Associate each private subnet with its AZ's private route table
resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
