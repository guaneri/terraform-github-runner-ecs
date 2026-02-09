# This file defines the outputs (returned values) from this Terraform module.
# Outputs expose important resource identifiers and information that can be used
# by other Terraform configurations, scripts, or for reference after deployment.
# These values are displayed after a successful terraform apply and can be
# queried using `terraform output` commands.

# ECS Cluster ID: An ECS cluster is a logical grouping of ECS tasks and services
# that run your containerized applications. This ID uniquely identifies the cluster
# within your AWS account and can be used to reference the cluster in AWS CLI
# commands or other Terraform configurations.
output "ecs_cluster_id" {
  description = "The ID of the ECS cluster."
  value       = module.runner_infra.ecs_cluster_id
  depends_on = [
    module.runner_infra
  ]
}

# ECS Cluster ARN: An ARN (Amazon Resource Name) is a unique identifier for AWS
# resources that includes the AWS account, region, service, and resource path.
# This ARN can be used in IAM policies to grant permissions to the cluster or
# to reference the cluster in other AWS services.
output "ecs_cluster_arn" {
  description = "The ARN of the ECS cluster."
  value       = module.runner_infra.ecs_cluster_arn
  depends_on = [
    module.runner_infra
  ]
}

# ECS Cluster Name: The human-readable name assigned to the ECS cluster.
# This name is used in the AWS Console and CLI commands to identify the cluster.
output "ecs_cluster_name" {
  description = "The name of the ECS cluster."
  value       = module.runner_infra.ecs_cluster_name
  depends_on = [
    module.runner_infra
  ]
}

# ECS Service Name (Legacy): An ECS service maintains a desired number of running
# tasks (containers) and automatically restarts failed tasks. This output provides
# the name of the first runner service when using a single service configuration.
# This is a legacy output maintained for backward compatibility.
output "ecs_service_name" {
  description = "Legacy: the name of the first ECS service (when runner_services is empty, this is the single runner service)."
  value       = module.runner_service[sort(keys(module.runner_service))[0]].ecs_service_name
}

# EC2 Capacity Provider Name: A capacity provider determines how ECS places tasks
# on compute resources. When using EC2 launch type, this capacity provider manages
# the EC2 instances that run your containers. The name can be used to reference
# this capacity provider in ECS service configurations.
output "ec2_capacity_provider_name" {
  description = "The name of the EC2 capacity provider (if EC2 launch type is used)."
  value       = module.runner_infra.ec2_capacity_provider_name
}

# Auto Scaling Group Name: An Auto Scaling Group (ASG) automatically adjusts the
# number of EC2 instances based on demand or configuration. This ASG manages the
# EC2 instances that run your GitHub Actions runners, scaling up or down as needed.
output "autoscaling_group_name" {
  description = "The name of the Auto Scaling Group (if EC2 launch type is used)."
  value       = module.runner_infra.autoscaling_group_name
}

# Launch Template ID: A Launch Template defines the configuration for EC2 instances,
# including the AMI, instance type, security groups, and user data. This ID uniquely
# identifies the template used to launch the EC2 instances that host your runners.
output "launch_template_id" {
  description = "The ID of the EC2 Launch Template (if EC2 launch type is used)."
  value       = module.runner_infra.launch_template_id
}

# Launch Template Name: The human-readable name of the EC2 Launch Template.
# This name is used in the AWS Console and CLI commands to identify the template.
output "launch_template_name" {
  description = "The name of the EC2 Launch Template (if EC2 launch type is used)."
  value       = module.runner_infra.launch_template_name
}

# ECS Service Names Map: When deploying multiple runner services (for different
# organizations or configurations), this output provides a map of all ECS service
# names keyed by their runner_services configuration key. This allows you to
# reference specific services by their logical name.
output "ecs_service_names" {
  description = "Map of ECS service names by runner_services key."
  value       = { for k, v in module.runner_service : k => v.ecs_service_name }
}

# Networking outputs (only when create_networking is true).
output "networking_vpc_id" {
  description = "ID of the VPC created by the networking module. Set only when create_networking is true."
  value       = var.create_networking ? module.networking[0].vpc_id : null
}

output "networking_subnet_ids" {
  description = "IDs of the subnets created by the networking module. Set only when create_networking is true."
  value       = var.create_networking ? module.networking[0].subnet_ids : null
}

output "networking_transit_gateway_id" {
  description = "ID of the Transit Gateway created by the networking module. Set only when create_networking is true."
  value       = var.create_networking ? module.networking[0].transit_gateway_id : null
}
