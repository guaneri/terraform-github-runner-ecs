###############################################################################
# Runner Service Module - ECS Task Definition + ECS Service
#
# This file defines the *workload layer* for the GitHub Actions runner (the runner is defined in the runner_service module and runs on the EC2 or fargate as defined in the runner_infra module):
# - An ECS Task Definition: the template describing how to run the runner container(s)
#   (image, env, logging, volumes, CPU/memory, etc.).
# - An ECS Service: the controller that keeps `desired_count` copies of the task running
#   on the selected capacity (EC2 “container instances” or Fargate) (as defined in runner_infra module).
###############################################################################

# Resource: ECS task definition for the GitHub runner workload.
#
# What it is:
# - ECS Task Definition: a versioned “run specification” for one or more containers.
#
# What it attaches to:
# - Referenced by `aws_ecs_service.github_runner_service.task_definition` below (so the service knows what to run).
resource "aws_ecs_task_definition" "github_runner" {
  # checkov:skip=CKV_AWS_249:Ensure that the Execution Role ARN and the Task Role ARN are different in ECS Task definitions because this is for local testing/development and actual production deployment will be configured properly.
  family                   = local.effective_ecs_task_family                   # Task definition family name; derived in `locals.tf`
  network_mode             = var.network_mode                                  # Task networking mode; from `var.network_mode` (commonly "awsvpc")
  requires_compatibilities = local.is_ec2_launch_type ? ["EC2"] : ["FARGATE"]  # Which capacity types this task can run on (EC2 vs Fargate)
  execution_role_arn       = aws_iam_role.runner_task_role.arn                 # Execution role (pull image, write logs, fetch secrets); role created in `iam.tf`
  task_role_arn            = aws_iam_role.runner_task_role.arn                 # Task role (AWS API access from inside container); role created in `iam.tf`
  cpu                      = local.is_ec2_launch_type ? null : var.task_cpu    # Fargate requires CPU; EC2 tasks can omit (uses host capacity)
  memory                   = local.is_ec2_launch_type ? null : var.task_memory # Fargate requires memory; EC2 tasks can omit (uses host capacity)

  # What it is: container definition JSON for the runner container(s).
  # Definition: ECS expects container definitions as JSON; we render it from `ecs_task_definition.json.tpl`.
  #
  # IMPORTANT:
  # - JSON does not support comments, and ecs_task_definition.json.tpl in runner_service module must render to valid JSON for ECS.
  # - So we document what ecs_task_definition.json.tpl in runner_service module does here (without changing the rendered output).
  #
  # Template overview (`ecs_task_definition.json.tpl`):
  # - **Container: `efs-init`** (non-essential)
  #   - Purpose: initialize directories on the mounted EFS volume and write a permissive `.gitconfig`
  #     (`safe.directory = *`) to avoid Git safety errors when Actions checks out repos as root.
  #   - Mounts: `${source_volume_name}` at `${container_path}` (EFS mount from the task `volume { name = "runner-efs" }`).
  #   - Logs: awslogs stream prefix `efs-init`.
  #
  # - **Container: `docker`** (optional, only when `enable_dind = true`)
  #   - Purpose: Docker-in-Docker sidecar (listens on `tcp://0.0.0.0:2375`) for jobs needing Docker.
  #   - Health check: `docker info` (runner waits for HEALTHY before starting).
  #   - Mounts: `${source_volume_name}` at `/home/runner` (so builds can access the workspace on EFS).
  #   - Logs: awslogs stream prefix `dind`.
  #
  # - **Container: `runner`** (essential)
  #   - DependsOn: `efs-init` COMPLETE; and (if enabled) `docker` HEALTHY.
  #   - Image: `"${aws_account_id}.dkr.ecr.${aws_region}.amazonaws.com/${runner_image}"`.
  #   - Privileged: `${runner_privileged}` (set when DinD enabled on EC2).
  #   - Secrets: `RUNNER_TOKEN` from SSM parameter
  #     `arn:aws:ssm:${aws_region}:${aws_account_id}:parameter/${runner_token_ssm_parameter_name}`.
  #   - Mounts:
  #     - EFS: `${source_volume_name}` at `/home/runner` (persistent workspace).
  #     - tmpfs: `runner-tmpfs` at `/runner` and `runner-data-tmpfs` at `/runner-data` (ephemeral).
  #   - Logs: awslogs stream prefix `runner`.
  #
  # Other notable behaviors in the template:
  # - Runner runs as root (`"user": "0:0"`) and sets `RUNNER_ALLOW_RUNASROOT=1`.
  # - Sets debug env vars (`ACTIONS_RUNNER_DEBUG` / `ACTIONS_STEP_DEBUG`) to `"true"`.
  # - Uses tmpfs mounts for `/runner` and `/runner-data` and EFS for `/home/runner`.
  #
  # Template inputs:
  # - See the inline comments on each `templatefile(...)` variable below for the precise mapping. (from aws_region to runner_privileged)
  #
  # Note: `read_only_volume` is currently passed into the template variables for future use/documentation;
  # the template currently mounts EFS with `"readOnly": false`.
  container_definitions = templatefile("${path.module}/ecs_task_definition.json.tpl", {
    aws_region                      = var.aws_region                              # AWS region the runner container uses (SDK/CLI/config); from `var.aws_region`
    aws_account_id                  = var.aws_account_id                          # AWS account id used for ARNs/templating; from `var.aws_account_id`
    log_group_name                  = aws_cloudwatch_log_group.github_runner.name # CloudWatch Logs group name for container logs; from `aws_cloudwatch_log_group.github_runner`
    runner_name_prefix              = var.runner_name_prefix                      # Prefix for runner names as they register in GitHub; from `var.runner_name_prefix`
    runner_scope                    = "org"                                       # Scope for runner registration (org-level runner); constant in this module
    runner_image                    = var.runner_image                            # Container image URI for the runner; from `var.runner_image`
    source_volume_name              = "runner-efs"                                # ECS volume name referenced by container definition; matches `volume { name = "runner-efs" }`
    container_path                  = "/home/runner"                              # Container path where EFS is mounted; used by the template/container definition
    read_only_volume                = var.read_only_volume                        # Whether to mount EFS read-only; from `var.read_only_volume`
    org_name                        = var.github_org                              # GitHub org to register the runner against; from `var.github_org`
    runner_labels                   = var.runner_labels                           # Runner labels (CSV); from `var.runner_labels`
    runner_token_ssm_parameter_name = var.runner_token_ssm_parameter_name         # SSM parameter name that stores the registration token; from `var.runner_token_ssm_parameter_name`
    enable_dind                     = local.is_ec2_launch_type && var.enable_dind # Enable Docker-in-Docker only on EC2 launch type; from `var.enable_dind`
    runner_privileged               = local.is_ec2_launch_type && var.enable_dind # Run runner container privileged when DinD is enabled; derived from launch type + `var.enable_dind`
  })

  # What it is: persistent EFS volume configuration for the task.
  # Definition: mounts an Amazon EFS filesystem into the container so data persists across task restarts.
  # What it attaches to: references EFS resources created in `efs.tf` (filesystem + access point).
  volume {
    name = "runner-efs" # Volume name referenced by container definitions (`sourceVolume`)
    # What it is: EFS volume configuration block for this task definition volume.
    # Definition: configures which EFS filesystem to mount and how (encryption + authorization) for the ECS task.
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.runner.id # EFS filesystem ID; from `efs.tf`
      transit_encryption = "ENABLED"                     # Encrypt NFS traffic in transit between task and EFS mount target
      # What it is: authorization configuration for the EFS mount.
      # Definition: uses an EFS access point + IAM authorization so mounts get consistent POSIX permissions and are authorized via IAM.
      authorization_config {
        access_point_id = aws_efs_access_point.runner.id # EFS access point ID; from `efs.tf`
        iam             = "ENABLED"                      # Use IAM authorization for EFS access point mounts
      }
    }
  }

  # tmpfs volume for /runner (like Kubernetes emptyDir)
  # Definition: an ephemeral scratch volume for temporary files; data is not persisted across task restarts (unlike EFS).
  volume {
    name = "runner-tmpfs" # Named scratch volume referenced by container definitions (used for temporary runtime data)
  }

  # tmpfs volume for /runner-data (like Kubernetes emptyDir)
  # Definition: a second ephemeral scratch volume for runner data; helps keep transient data off the persistent EFS mount.
  volume {
    name = "runner-data-tmpfs" # Named scratch volume referenced by container definitions (used for temporary runtime data)
  }

  # What it is: explicit dependency list for Terraform's resource graph.
  # Definition: helps avoid a first-run race by ensuring EFS mount targets exist before task definition registration.
  depends_on = [
    aws_efs_mount_target.mt_az1, # Ensure EFS mount target exists in subnet/AZ 0 before first task startup
    aws_efs_mount_target.mt_az2  # Ensure EFS mount target exists in subnet/AZ 1 before first task startup
  ]
}

# Resource: ECS service that runs and maintains the runner tasks.
#
# What it is:
# - ECS Service: keeps `desired_count` tasks running and handles deployments/rollouts.
#
# What it attaches to:
# - Attaches to the ECS cluster (`var.cluster_id`) and runs the task definition above.
# - Applies network settings (subnets/SGs) and optional capacity provider strategy.
resource "aws_ecs_service" "github_runner_service" {
  name                               = local.effective_ecs_service_name          # ECS service name string; derived in `locals.tf`
  cluster                            = var.cluster_id                            # ECS cluster id/arn to run in; from `var.cluster_id` (typically output of `runner_infra`)
  task_definition                    = aws_ecs_task_definition.github_runner.arn # Task definition to run; from `aws_ecs_task_definition.github_runner.arn`
  desired_count                      = var.desired_count                         # Number of runner tasks to keep running; from `var.desired_count`
  enable_execute_command             = true                                      # Enable ECS Exec into running tasks for troubleshooting
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent    # Minimum % of tasks that must remain healthy during deployments (100 = no scale-down)
  deployment_maximum_percent         = var.deployment_maximum_percent            # Maximum % of tasks allowed during deployments (200 = allow a 100% surge)

  # What it is: deployment circuit breaker configuration.
  # Definition: automatically rolls back a deployment if it fails to reach steady state.
  deployment_circuit_breaker {
    enable   = true # Enable circuit breaker (detect failed deployments)
    rollback = true # Automatically roll back to the last stable task definition on failure
  }

  # What it is: optional capacity provider strategy.
  # Definition: tells ECS which capacity provider to place tasks on (when using EC2 launch type + a named capacity provider).
  dynamic "capacity_provider_strategy" {
    for_each = local.is_ec2_launch_type && try(trimspace(var.capacity_provider_name), "") != "" ? [1] : [] # Emit block only when EC2 launch type and a capacity provider name is set
    # What it is: the contents of the dynamically-rendered capacity provider strategy block.
    content {
      capacity_provider = var.capacity_provider_name # Capacity provider name (usually from `runner_infra` output); from `var.capacity_provider_name`
      weight            = 1                          # Relative weight (single provider here)
    }
  }

  # What it is: VPC networking configuration for the tasks.
  # Definition: for `awsvpc` tasks, ECS creates a task ENI in these subnets and attaches these security groups.
  network_configuration {
    subnets         = var.subnets                                                          # Subnets where task ENIs are created (awsvpc); from `var.subnets`

    # Always attach the module's runner_tasks SG (required for EFS access + baseline egress),
    # and optionally add any extra SGs provided via `var.security_group_ids`.
    security_groups = concat(
      [aws_security_group.runner_tasks.id],
      var.security_group_ids
    )

    # assign_public_ip is only meaningful for Fargate tasks.
    assign_public_ip = local.is_ec2_launch_type ? false : var.assign_public_ip # For EC2 tasks keep false; for Fargate, follow `var.assign_public_ip`
  }
} # End ECS service definition (ECS keeps `desired_count` tasks running)


