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

# One private subnet per AZ; CIDR is derived from VPC CIDR so no overlap.
resource "aws_subnet" "private" {
  count             = length(var.networking_azs)
  vpc_id            = aws_vpc.main.id
  availability_zone = var.networking_azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  tags = {
    Name = "${var.name_prefix}-private-${var.networking_azs[count.index]}"
  }
}

# TGW VPC attachment: attach the VPC to the Transit Gateway.
resource "aws_ec2_transit_gateway_vpc_attachment" "main" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.main.id
  subnet_ids         = aws_subnet.private[*].id
  dns_support         = "enable"
  ipv6_support        = "disable"
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
