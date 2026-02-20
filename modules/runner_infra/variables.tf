################################################################################
# Runner Infra Module - Input Variables
################################################################################
#
# This file defines all input variables for the `runner_infra` Terraform module.
# These inputs control the shared AWS infrastructure that runner services run on:
# - **ECS cluster**: a logical “pool” in Amazon ECS where services/tasks run.
# - **EC2 capacity**: optional “worker” EC2 instances (via an Auto Scaling Group)
#   that the ECS cluster uses to place containers when `launch_type = "EC2"`.
# - **Networking**: which VPC/subnets/security groups the instances use.
# - **Maintenance**: optional host-level cleanup to prevent Docker disk bloat.
#
# Each variable below includes:
# - A short comment explaining what it is/does (for quick scanning)
# - A Terraform `description` attribute used by `terraform docs` and validation
#
################################################################################

# Name of the ECS cluster.
# An ECS cluster is the “place” ECS schedules containers into (either onto EC2 instances or Fargate).
variable "cluster_name" {
  description = "Name of the ECS cluster"
  type        = string
}

# Whether this module should create the ECS cluster.
# Set `false` if you already have an ECS cluster and only want this module to manage capacity/networking pieces.
variable "create_cluster" {
  description = "Whether to create a new ECS cluster or use an existing one."
  type        = bool
  default     = true
}

# Compute model for running runner containers.
# - **EC2**: you run an Auto Scaling Group (ASG) of EC2 instances; ECS places runner containers onto those instances.
# - **FARGATE**: AWS runs the compute for you; no EC2 instances/ASG/AMI/instance type needed.
variable "launch_type" {
  description = "Launch type for the ECS cluster capacity providers (EC2 or FARGATE)."
  type        = string
  default     = "EC2"
}

# Whether this module manages ECS capacity providers / default capacity provider strategy.
# Capacity providers tell ECS *how* to find compute capacity (for EC2, typically via an ASG).
variable "manage_cluster_capacity_providers" {
  description = "Whether this module should manage cluster capacity providers/default strategy."
  type        = bool
  default     = true
}

# AWS region where resources are created (for example `us-east-1`).
variable "aws_region" {
  description = "AWS region"
  type        = string
}

# VPC ID where the infrastructure lives.
# A VPC is your private network in AWS; subnets and security groups are created/used inside it.
variable "vpc_id" {
  description = "VPC id"
  type        = string
}

# Subnet IDs used for EC2 instances (and for task networking/mount targets).
# A subnet is a slice of your VPC in a specific Availability Zone; use at least two for resilience.
variable "subnets" {
  description = "List of subnet IDs for the EC2 Auto Scaling Group (and for tasks networking if you run EC2 tasks with awsvpc)."
  type        = list(string)
}

# Additional security group IDs to attach to EC2 instances.
# A security group is a virtual firewall; these are added *in addition to* any security group this module creates/manages.
variable "security_group_ids" {
  description = "Optional: Additional security group IDs to attach to the EC2 instances."
  type        = list(string)
  default     = []
}

# Whether EC2 instances should get a public IP address.
# This typically stays `false` for private subnets behind NAT; set `true` only if launching into public subnets intentionally.
variable "assign_public_ip" {
  description = "Whether to associate a public IP on the EC2 instance ENI (only relevant when instances are launched in public subnets)."
  type        = bool
  default     = false
}

# AMI ID used to boot the EC2 instances (only used when `launch_type = "EC2"`).
# An AMI is an “OS image” for EC2; you typically want the ECS-optimized AMI so Docker + ECS agent are preinstalled.
variable "instance_ami" {
  description = "Optional: AMI ID for EC2 instances. If null or empty, the latest ECS-optimized AMI will be auto-discovered. AMI ID for the EC2 instances (ECS-optimized recommended). Required when launch_type=EC2."
  type        = string
  default     = null
}

# EC2 instance type (size) for the container instances (only used when `launch_type = "EC2"`).
# This controls how much CPU/RAM each instance has for running runner containers (for example `t3.medium`, `m6i.large`).
variable "instance_type" {
  description = "EC2 instance type for the ECS container instances."
  type        = string
  default     = "t3.medium"
}

# Auto Scaling Group minimum size (baseline number of EC2 instances).
# Set to `0` if you want the option to scale down to zero when idle (cost saver, but cold starts are slower).
variable "asg_min_size" {
  description = "Minimum size of the Auto Scaling Group"
  type        = number
  default     = 0
}

# Auto Scaling Group maximum size (hard cap on EC2 instances).
# This protects you from runaway scaling/costs.
variable "asg_max_size" {
  description = "Maximum size of the Auto Scaling Group"
  type        = number
  default     = 5
}

# Auto Scaling Group desired capacity (the “target” number of EC2 instances to run).
# AWS will try to keep the ASG at this size, within the min/max bounds.
variable "asg_desired_capacity" {
  description = "Desired capacity of the Auto Scaling Group"
  type        = number
  default     = 1
}

# Name prefix used when creating shared infrastructure resources.
# This helps you identify resources in AWS (launch template, ASG, instance role/profile, security group, capacity provider, etc.).
variable "infra_name_prefix" {
  description = "Prefix used to name shared infra resources (ASG, launch template, instance role/profile, instance SG, capacity provider)."
  type        = string
  default     = ""
}

# Whether to install a scheduled Docker cleanup on EC2 instances.
# Docker can accumulate stopped containers/images over time; this helps prevent “disk full” failures on long-lived hosts.
variable "enable_docker_prune_cron" {
  description = "Whether to install a cron job on the EC2 container instances to prune stopped containers/unused images/networks/volumes."
  type        = bool
  default     = false
}

# Cron schedule for when the Docker cleanup runs (minute hour day-of-month month day-of-week).
# Example: `"0 * * * *"` runs hourly; `"0 2 * * *"` runs daily at 2am.
variable "docker_prune_cron_schedule" {
  description = "Cron schedule (min hour dom mon dow) for docker prune job."
  type        = string
  default     = "0 * * * *"
}

# Age threshold for Docker cleanup (only unused resources older than this are removed).
# Example: `"3h"` removes resources unused for 3 hours; `"168h"` is one week.
variable "docker_prune_until" {
  description = "Docker prune 'until' filter (for example: 24h, 168h, 3h). Only resources unused for at least this duration will be pruned."
  type        = string
  default     = "3h"
}

# Size (GiB) of the extra EBS volume used for Docker data (`/var/lib/docker`).
# Runner workloads that build images can consume a lot of disk; increasing this reduces “no space left on device”.
variable "docker_volume_size" {
  description = "Size in GB for the additional EBS volume used for Docker data (/var/lib/docker)."
  type        = number
  default     = 100
}


