# This file defines all input variables for the Terraform configuration.
# These variables control the deployment of GitHub Actions runners on AWS ECS,
# including infrastructure settings (cluster, VPC, subnets), runner configuration
# (image, labels, count), and optional features (Docker pruning, multi-service support).
# Variables can be provided via .tfvars files, environment variables (TF_VAR_*),
# or command-line flags when running Terraform commands.

# The name of the ECS cluster where your GitHub runners will run. Think of it as a group that manages all your runner containers.
variable "cluster_name" {
  description = "Name of the ECS cluster for the GitHub runner"
  type        = string
  default     = "nexus-repo"
}

# Which AWS region (like us-east-1) to create all the resources in. All your runners and infrastructure will be in this region.
variable "aws_region" {
  description = "AWS region to deploy the GitHub runner resources"
  type        = string
}

# Your 12-digit AWS account number. Used to create resource names and permissions.
variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

# List of subnet IDs where the runners will be deployed. You need at least 2 subnets (usually in different zones) for high availability.
# A subnet is a range of IP addresses in your VPC (Virtual Private Cloud) - think of it as a specific network segment within your larger network where your resources can be placed.
variable "subnets" {
  description = "List of subnet IDs for the GitHub runner ECS service. Required."
  type        = list(string)
  default     = []
}

# The Docker image that contains the GitHub Actions runner software. This is what actually runs your workflows.
variable "runner_image" {
  description = "Docker image for the GitHub runner"
  type        = string
  default     = "github-runner:latest"
}

# The prefix that appears in GitHub's runner list. GitHub will add a unique ID, so you'll see names like "ecs-github-runner-abc123".
variable "runner_name_prefix" {
  description = "Prefix for the GitHub runner name"
  type        = string
  default     = "ecs-github-runner"
}

# Labels that identify this runner type. Used in workflows with "runs-on: [label1, label2]" to target specific runners.
variable "runner_labels" {
  description = "Comma-separated labels for the GitHub runner (passed to the runner container as LABELS)."
  type        = string
  default     = "self-hosted,ph-dev,ec2,ecs"
}

# The GitHub organization or repository name where this runner will register. Format: "org-name" for org runners or "owner/repo" for repo runners.
variable "github_org" {
  description = "GitHub repository name (e.g., 'owner/repo' or 'owner' for organization-level runner)"
  type        = string
  default     = ""
}

# How many runner containers you want running at the same time. More runners = more workflows can run in parallel.
variable "desired_count" {
  description = "Desired number of GitHub runner tasks"
  type        = number
  default     = 1
}

# ECS service deployment configuration (rolling update behavior).
# These defaults match AWS ECS common safe settings:
# - min healthy 100: no scale-down during deployment (avoid capacity drop)
# - max percent 200: allow a 100% surge during deployment (faster/safer rollouts)
variable "deployment_minimum_healthy_percent" {
  description = "ECS service deployment minimum healthy percent (default 100 = no scale-down during deployments)."
  type        = number
  default     = 100
}

variable "deployment_maximum_percent" {
  description = "ECS service deployment maximum percent (default 200 = allow 100% surge during deployments)."
  type        = number
  default     = 200
}

# The name/path in AWS Parameter Store where the GitHub runner registration token is stored. The runner uses this to connect to GitHub.
variable "runner_token_ssm_parameter_name" {
  description = "Name of the SSM parameter storing the GitHub runner token"
  type        = string
  sensitive   = true
  default     = ""
}

# Whether to run on EC2 (your own servers) or FARGATE (AWS-managed servers). EC2 gives more control, Fargate is simpler.
variable "launch_type" {
  description = "Launch type for the ECS service (EC2 or FARGATE)"
  type        = string
  default     = "EC2"
}

# The operating system image (AMI) for your EC2 instances. Must be an ECS-optimized AMI that has Docker and ECS agent pre-installed.
variable "instance_ami" {
  description = "AMI ID for the EC2 instances"
  type        = string
  default     = ""
}

# The size/type of EC2 instance (like t3.medium, t3.large). Bigger instances = more CPU/memory but cost more.
variable "instance_type" {
  description = "EC2 instance type for the GitHub runner"
  type        = string
  default     = "t3.medium"
}

# Minimum number of EC2 instances that will always be running, even if there's no work. Set to 0 to save money when idle.
variable "asg_min_size" {
  description = "Minimum size of the Auto Scaling Group"
  type        = number
  default     = 0
}

# Maximum number of EC2 instances that can be created. Prevents runaway scaling and controls costs.
variable "asg_max_size" {
  description = "Maximum size of the Auto Scaling Group"
  type        = number
  default     = 5
}

# How many EC2 instances to start with initially. The Auto Scaling Group will try to maintain this many.
variable "asg_desired_capacity" {
  description = "Desired capacity of the Auto Scaling Group"
  type        = number
  default     = 1
}

# If true, creates a new ECS cluster. If false, uses an existing cluster (useful if you already have one).
variable "create_cluster" {
  description = "Whether to create a new ECS cluster or use an existing one."
  type        = bool
  default     = true
}

# The ID of your Virtual Private Cloud (VPC). This is the network where all your runners will live.
variable "vpc_id" {
  description = "VPC ID. Required."
  type        = string
  default     = ""
}

# Optional prefix added to all AWS resource names. Use this if deploying multiple orgs to the same AWS account to avoid name conflicts.
variable "resource_name_prefix" {
  description = "Optional: Prefix used to name AWS resources created by this stack. Set a unique value per GitHub org (required if deploying multiple org runners into the same AWS account/region)."
  type        = string
  default     = ""
}

# Optional list of security group IDs to attach. Security groups act like firewalls controlling network traffic. The module creates its own for EFS access.
variable "security_group_ids" {
  description = "Optional: Additional security group IDs to attach to the ECS tasks/EC2 instances (the module still creates its own SGs for EFS access)."
  type        = list(string)
  default     = []
}

# Prefix for naming shared infrastructure resources (Auto Scaling Group, launch template, capacity provider). If empty, uses cluster_name.
variable "infra_name_prefix" {
  description = "Prefix used to name shared ECS infra resources (ASG/launch template/capacity provider). If empty, derived from cluster_name."
  type        = string
  default     = ""
}

# If true, automatically cleans up old Docker containers and images on a schedule. Prevents disk space issues over time.
variable "enable_docker_prune_cron" {
  description = "Whether to install a cron job on the EC2 container instances to prune stopped containers/unused images/networks/volumes."
  type        = bool
  default     = false
}

# When to run the Docker cleanup job, in cron format (minute hour day-of-month month day-of-week). Example: "0 * * * *" = every hour at minute 0.
variable "docker_prune_cron_schedule" {
  description = "Cron schedule (min hour dom mon dow) for docker prune job."
  type        = string
  default     = "0 * * * *"
}

# How old Docker resources need to be before they get cleaned up. Examples: "3h" = 3 hours, "24h" = 1 day, "168h" = 1 week.
variable "docker_prune_until" {
  description = "Docker prune 'until' filter (for example: 24h, 168h, 3h). Only resources unused for at least this duration will be pruned."
  type        = string
  default     = "3h"
}

# Advanced: Map of multiple runner services to deploy in the same cluster. Each service can have different org, labels, image, etc.
variable "runner_services" {
  description = "Map of runner services to deploy in the same ECS cluster. Each value must include github_org and runner_token_ssm_parameter_name."
  type = map(object({
    github_org                      = string # GitHub organization name where the runner will register (e.g., "my-company")
    runner_token_ssm_parameter_name = string # SSM Parameter Store path where the GitHub runner registration token is stored (e.g., "github-runner/token")

    desired_count        = optional(number) # Number of runner containers to run simultaneously for this service (defaults to top-level desired_count)
    runner_image         = optional(string) # Docker image URI for this runner service (defaults to top-level runner_image)
    runner_name_prefix   = optional(string) # Prefix for runner names in GitHub UI (defaults to top-level runner_name_prefix)
    runner_labels        = optional(string) # Comma-separated labels for workflow targeting (defaults to top-level runner_labels)
    resource_name_prefix = optional(string) # Prefix for AWS resource names (ECS service, task definition, etc.) - defaults to service key name

    deployment_minimum_healthy_percent = optional(number) # ECS deployment min healthy % (defaults to top-level deployment_minimum_healthy_percent)
    deployment_maximum_percent         = optional(number) # ECS deployment max % (defaults to top-level deployment_maximum_percent)

    security_group_ids = optional(list(string)) # List of security group IDs for this service's network access (defaults to top-level security_group_ids)
    assign_public_ip   = optional(bool)         # Whether to assign a public IP address to tasks (defaults to top-level assign_public_ip)
    enable_dind        = optional(bool)         # Whether to enable Docker-in-Docker for building Docker images (defaults to top-level enable_dind)
  }))
  default = {}
}

# Whether to give the runner a public IP address. Usually false (runners use private IPs and access internet via NAT gateway).
variable "assign_public_ip" {
  description = "Whether to assign a public IP. For launch_type=FARGATE this controls the task ENI public IP. For launch_type=EC2 this controls associating a public IP to the EC2 instance ENI (ECS task ENIs will not get a public IP)."
  type        = bool
  default     = false
}

# Size in gigabytes of the extra disk volume used for Docker data. Docker images and containers can use a lot of space, so 100GB is a good default.
variable "docker_volume_size" {
  description = "Size in GB for the additional EBS volume used for Docker data (/var/lib/docker)."
  type        = number
  default     = 100
}