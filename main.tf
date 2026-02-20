# ============================================================================
# Main Terraform Configuration for GitHub Actions Runner Infrastructure
# ============================================================================
#
# This file orchestrates the deployment of GitHub Actions self-hosted runners
# on AWS ECS. It manages:
#
# 1. Input validation - Ensures required variables are set based on launch type
#    and runner service configuration
# 2. Infrastructure module - Creates shared ECS cluster, capacity providers,
#    networking, and EC2 instances (if using EC2 launch type)
# 3. Runner service modules - Creates one or more ECS services that run
#    GitHub Actions runner containers, supporting multiple organizations or
#    repositories
#
# The configuration supports both single and multi-organization deployments:
# - Single org: Uses top-level variables (github_org, runner_token_ssm_parameter_name)
# - Multi-org: Uses runner_services map to define multiple services with
#   different configurations
#
# How Variables Get Their Values:
# Variables like var.launch_type are populated from multiple sources in priority order:
# 1. Command-line flags: terraform apply -var="launch_type=FARGATE"
# 2. Environment variables: TF_VAR_launch_type=FARGATE (used by GitHub Actions workflow)
# 3. .tfvars files: -var-file="env/multi-org.tfvars" (contains launch_type = "EC2")
# 4. Variable defaults: The default value defined in variables.tf (if no other source provides it)
#
# The GitHub Actions workflow (deployment.yml) uses environment variables (TF_VAR_*) to pass
# configuration values to Terraform, which is why you see TF_VAR_launch_type, TF_VAR_vpc_id,
# etc. in the workflow file. These automatically become var.launch_type, var.vpc_id, etc.
# in Terraform.
# ============================================================================

# When runner_services is empty, fall back to a single "default" service.
# Explicitly cast to a map so the conditional type matches var.runner_services (map(object(...))).
locals {
  _default_runner_services = tomap({
    default = {
      github_org                      = var.github_org
      runner_token_ssm_parameter_name = var.runner_token_ssm_parameter_name

      desired_count        = null
      runner_image         = null
      runner_name_prefix   = null
      runner_labels        = null
      resource_name_prefix = null
      security_group_ids   = null
      assign_public_ip     = false
      enable_dind          = null

      deployment_minimum_healthy_percent = null
      deployment_maximum_percent         = null
    }
  })

  effective_runner_services = length(var.runner_services) > 0 ? var.runner_services : local._default_runner_services

  # When create_networking is true, use networking module outputs; otherwise use provided vpc_id and subnets.
  effective_vpc_id  = var.create_networking ? module.networking[0].vpc_id : var.vpc_id
  effective_subnets = var.create_networking ? module.networking[0].subnet_ids : var.subnets
}

# Input validation resource
# Validates that required variables are set based on the configuration mode
# (single org vs multi-org, EC2 vs Fargate launch type)
resource "terraform_data" "validate_inputs" {
  input = {
    launch_type      = var.launch_type
    image_id = var.instance_ami
    runner_services  = var.runner_services
    github_org       = var.github_org
    runner_token_ssm = var.runner_token_ssm_parameter_name
  }

  lifecycle {
    # Validates that github_org is set when using single-org mode (runner_services is empty)
    precondition {
      condition     = length(var.runner_services) > 0 || trimspace(var.github_org) != ""
      error_message = "When runner_services is empty, github_org must be set."
    }

    # Validates that runner_token_ssm_parameter_name is set when using single-org mode
    precondition {
      condition     = length(var.runner_services) > 0 || trimspace(var.runner_token_ssm_parameter_name) != ""
      error_message = "When runner_services is empty, runner_token_ssm_parameter_name must be set."
    }

    # Validates that each entry in runner_services has required fields (github_org and token parameter name)
    precondition {
      condition = length(var.runner_services) == 0 ? true : alltrue([
        for k, v in var.runner_services :
        try(trimspace(v.github_org) != "", false) && try(trimspace(v.runner_token_ssm_parameter_name) != "", false)
      ])
      error_message = "Each runner_services entry must include non-empty github_org and runner_token_ssm_parameter_name."
    }

    # When create_networking is false, vpc_id and subnets must be provided.
    precondition {
      condition     = var.create_networking || (trimspace(var.vpc_id) != "" && length(var.subnets) > 0)
      error_message = "When create_networking is false, vpc_id and subnets must both be set."
    }

    # When create_networking is true, vpc_cidr and networking_azs must be provided.
    precondition {
      condition     = !var.create_networking || (trimspace(var.vpc_cidr) != "" && length(var.networking_azs) > 0)
      error_message = "When create_networking is true, vpc_cidr and networking_azs must both be set."
    }

    # Optional additional CIDRs must be non-empty and unique.
    precondition {
      condition = !var.create_networking || (
        alltrue([for c in var.vpc_additional_cidrs : trimspace(c) != ""]) &&
        length(distinct(concat([var.vpc_cidr], var.vpc_additional_cidrs))) == length(var.vpc_additional_cidrs) + 1
      )
      error_message = "When create_networking is true, vpc_additional_cidrs must not contain empty or duplicate CIDR values."
    }
  }
}

# Networking module: VPC, subnets, Transit Gateway, TGW attachment, and route (0.0.0.0/0 -> TGW).
# Only created when create_networking is true; otherwise use existing vpc_id and subnets.
module "networking" {
  count  = var.create_networking ? 1 : 0
  source = "./modules/networking"

  vpc_cidr             = var.vpc_cidr
  vpc_additional_cidrs = var.vpc_additional_cidrs
  networking_azs       = var.networking_azs
  name_prefix          = coalesce(trimspace(var.infra_name_prefix), var.cluster_name)
}

# Infrastructure module
# Creates the shared ECS cluster, capacity providers, networking resources,
# and EC2 Auto Scaling Group (if using EC2 launch type)
module "runner_infra" {
  source     = "./modules/runner_infra"
  depends_on = [terraform_data.validate_inputs]

  aws_region         = var.aws_region         # AWS region where all resources will be created (e.g., us-east-1)
  cluster_name       = var.cluster_name       # Name of the ECS cluster that will manage the runner containers
  create_cluster     = var.create_cluster     # Whether to create a new ECS cluster (false = use existing cluster)
  launch_type        = var.launch_type        # ECS launch type: "EC2" (your own servers) or "FARGATE" (AWS-managed)
  vpc_id             = var.vpc_id             # ID of the Virtual Private Cloud (network) where runners will be deployed
  subnets            = var.subnets            # List of subnet IDs where runners will run (need at least 2 for high availability)
  security_group_ids = var.security_group_ids # List of security group IDs for network firewall rules
  assign_public_ip   = false                  # Whether to assign public IP addresses (usually false for private subnets)

  instance_ami         = var.instance_ami         # Amazon Machine Image ID for EC2 instances (ECS-optimized AMI with Docker pre-installed)
  instance_type        = var.instance_type        # EC2 instance size/type (e.g., t3.medium, t3.large) - controls CPU/memory
  asg_min_size         = var.asg_min_size         # Minimum number of EC2 instances to keep running (0 = can scale to zero)
  asg_max_size         = var.asg_max_size         # Maximum number of EC2 instances that can be created (prevents runaway costs)
  asg_desired_capacity = var.asg_desired_capacity # Initial/target number of EC2 instances to run

  infra_name_prefix = var.infra_name_prefix # Prefix for naming shared infrastructure resources (ASG, launch template, etc.)

  # Docker prune job (runs on the EC2 container instances via user_data)
  # Automatically cleans up old Docker images, containers, and volumes to prevent disk space issues
  enable_docker_prune_cron   = var.enable_docker_prune_cron   # Whether to enable automatic Docker cleanup cron job
  docker_prune_cron_schedule = var.docker_prune_cron_schedule # Cron schedule for cleanup (e.g., "0 * * * *" = hourly)
  docker_prune_until         = var.docker_prune_until         # Age threshold for cleanup (e.g., "3h" = remove resources older than 3 hours)
  docker_volume_size         = var.docker_volume_size         # Size in GB of the EBS volume for Docker data storage
}

# Runner service modules
# Creates one or more ECS services that run GitHub Actions runner containers.
# Uses for_each to support multiple organizations/repositories, each with
# their own configuration (GitHub org, token, labels, image, etc.)
module "runner_service" {
  for_each   = local.effective_runner_services # Creates one service per entry in runner_services map (or single "default" service)
  source     = "./modules/runner_service"
  depends_on = [terraform_data.validate_inputs]

  aws_region     = var.aws_region     # AWS region where the runner service will be deployed
  aws_account_id = var.aws_account_id # 12-digit AWS account ID (used for constructing ARNs and resource names)

  cluster_id   = module.runner_infra.ecs_cluster_id   # ID of the ECS cluster (from runner_infra module output)
  cluster_name = module.runner_infra.ecs_cluster_name # Name of the ECS cluster (from runner_infra module output)

  launch_type            = var.launch_type                                # ECS launch type: "EC2" or "FARGATE"
  capacity_provider_name = module.runner_infra.ec2_capacity_provider_name # Name of the EC2 capacity provider (from runner_infra module output)

  vpc_id             = local.effective_vpc_id                                              # VPC: from networking module when create_networking, else var.vpc_id
  subnets            = local.effective_subnets                                             # Subnets: from networking module when create_networking, else var.subnets
  # Security groups attached to the ECS service ENIs.
  # Precedence:
  # 1. Service-specific security_group_ids (each.value.security_group_ids)
  # 2. Top-level var.security_group_ids (for BYO networking mode)
  # 3. Module-created default runner_tasks SG (used when create_networking = true)
  #
  # This guarantees at least one non-null SG list when networking is created
  # and avoids coalescelist() failing due to null/empty inputs.
  security_group_ids = coalescelist(
    try(each.value.security_group_ids, null),
    var.security_group_ids,
    var.create_networking ? [aws_security_group.runner_tasks.id] : null
  )
  assign_public_ip   = false                                                               # Whether to assign public IP addresses to tasks (usually false)

  github_org                      = each.value.github_org                      # GitHub organization name where this runner will register (from runner_services map)
  runner_token_ssm_parameter_name = each.value.runner_token_ssm_parameter_name # SSM Parameter Store path where the GitHub registration token is stored

  runner_image       = coalesce(each.value.runner_image, var.runner_image)             # Docker image URI for the runner (service-specific or top-level default)
  runner_name_prefix = coalesce(each.value.runner_name_prefix, var.runner_name_prefix) # Prefix for runner names in GitHub UI (service-specific or top-level default)
  runner_labels      = coalesce(each.value.runner_labels, var.runner_labels)           # Comma-separated labels for workflow targeting (service-specific or top-level default)
  desired_count      = coalesce(each.value.desired_count, var.desired_count)           # Number of runner containers to run simultaneously (service-specific or top-level default)

  deployment_minimum_healthy_percent = coalesce(each.value.deployment_minimum_healthy_percent, var.deployment_minimum_healthy_percent) # ECS deployment min healthy % (service-specific or top-level default)
  deployment_maximum_percent         = coalesce(each.value.deployment_maximum_percent, var.deployment_maximum_percent)                 # ECS deployment max % (service-specific or top-level default)

  # coalesce() rejects empty strings; allow null/empty => ""
  resource_name_prefix = trimspace(coalesce(each.value.resource_name_prefix, " ")) # Prefix for AWS resource names (ECS service, task definition, etc.) - defaults to service key name

  enable_dind = coalesce(each.value.enable_dind, true) # Whether to enable Docker-in-Docker for building Docker images in workflows
}
