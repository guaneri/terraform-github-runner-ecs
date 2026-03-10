################################################################################
# Networking Module - Outputs
################################################################################

output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidrs" {
  description = "All IPv4 CIDR blocks associated with the created VPC (primary + optional additional CIDRs)."
  value       = concat([aws_vpc.main.cidr_block], aws_vpc_ipv4_cidr_block_association.additional[*].cidr_block)
}

output "subnet_ids" {
  description = "IDs of the created private subnets (one per AZ)."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_ids" {
  description = "IDs of the created NAT gateways (one per AZ)."
  value       = aws_nat_gateway.main[*].id
}

output "route_table_ids" {
  description = "IDs of the private subnet route tables (one per AZ, 0.0.0.0/0 -> NAT gateway)."
  value       = aws_route_table.private[*].id
}
