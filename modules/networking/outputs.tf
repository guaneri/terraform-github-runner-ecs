################################################################################
# Networking Module - Outputs
################################################################################

output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.main.id
}

output "subnet_ids" {
  description = "IDs of the created private subnets (one per AZ)."
  value       = aws_subnet.private[*].id
}

output "transit_gateway_id" {
  description = "ID of the created Transit Gateway."
  value       = aws_ec2_transit_gateway.main.id
}

output "route_table_id" {
  description = "ID of the route table used by the private subnets (0.0.0.0/0 -> TGW)."
  value       = aws_route_table.private.id
}
