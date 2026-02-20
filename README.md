# How to Set Up GitHub Actions Runners on AWS

This guide will help you deploy your own GitHub Actions runners on Amazon Web Services (AWS). Think of this as creating your own computers in the cloud that can run your GitHub Actions workflows instead of using GitHub's shared runners.

## Table of Contents

- [Quick Overview](#quick-overview)
- [What You're Building](#what-youre-building)
- [Features](#features)
- [Repository layout](#repository-layout)
- [Architecture](#architecture)
  - [Network ingress/egress (connecting to runners)](#network-ingressegress-connecting-to-runners)
  - [Autoscaling and scale configuration](#autoscaling-and-scale-configuration)
  - [Third-party connectivity](#third-party-connectivity)
  - [Permissions management](#permissions-management)
- [What You Need Before Starting](#what-you-need-before-starting)
- [Step-by-Step Setup Guide](#step-by-step-setup-guide)
  - [Step 1: Get Your AWS Account Information](#step-1-get-your-aws-account-information)
  - [Step 2: Understand the Deployment Workflows](#step-2-understand-the-deployment-workflows)
  - [Step 3: Set Up Your VPC (Virtual Network)](#step-3-set-up-your-vpc-virtual-network)
  - [Step 4: Get a GitHub Runner Token](#step-4-get-a-github-runner-token)
  - [Step 5: Save the Token Securely in AWS](#step-5-save-the-token-securely-in-aws)
  - [Step 6: Build and Upload the Runner Docker Image](#step-6-build-and-upload-the-runner-docker-image)
  - [Step 7: Create Infrastructure Config File](#step-7-create-infrastructure-config-file)
  - [Step 8: Set Up GitHub Secrets and Variables](#step-8-set-up-github-secrets-and-variables)
  - [Step 9: Deploy Everything](#step-9-deploy-everything)
  - [Step 10: Check That It Works](#step-10-check-that-it-works)
- [Using Your Runners](#using-your-runners)
- [What Each Setting Does](#what-each-setting-does)
- [Common Problems and Solutions](#common-problems-and-solutions)
- [Removing Everything](#removing-everything)

## Quick Overview

**What is this?** A way to run your GitHub Actions workflows on your own computers in AWS instead of using GitHub's shared runners.

**Why would you want this?**
- More control over the environment
- Can use your own tools and configurations
- Can access private AWS resources easily
- Potentially cheaper for high usage

**How long does it take?** About 30-60 minutes for your first setup.

**What you'll need:**
- AWS account with permissions to create resources
- Basic command-line knowledge
- About $20-50/month in AWS costs (depending on usage)

## What You're Building

You're going to create:
- **GitHub Runners**: Computers in AWS that can run your GitHub Actions workflows
- **ECS Cluster**: A way to manage and run multiple runners
- **Storage**: A place to save runner settings so they don't get lost when restarted
- **Security**: Encrypted storage and secure token management

## Features

- **EC2 or Fargate** – You can run the runners on either regular virtual machines (EC2) or on serverless containers (Fargate). Pick what fits your team and budget.
- **Auto Scaling** – When more work shows up, AWS adds more runners. When things are quiet, it scales down so you’re not paying for idle machines.
- **Encrypted storage (EFS)** – Runner settings and data are stored on a shared drive that’s encrypted so only your account can read it.
- **Secure token storage (SSM Parameter Store)** – The secret token that lets runners talk to GitHub is stored in AWS, not in your code or config files.
- **CloudWatch logging** – Logs from the runners go to AWS CloudWatch so you can search and debug when something goes wrong.
- **Automatic cleanup** – Old containers, images, and volumes are cleaned up so the runner machines don’t run out of disk space.

## Repository layout

This repository is organized as follows:

- **Root Terraform** – `main.tf` (orchestration, networking module wiring, runner_infra and runner_service), `variables.tf`, `outputs.tf`, `providers.tf`. Optional `env/*.tfvars` for local or CI overrides.
- **Terraform modules**
  - `modules/runner_infra` – ECS cluster, capacity providers, EC2 ASG (if EC2 launch type), security groups.
  - `modules/runner_service` – ECS service, task definition, EFS, KMS, security groups per runner service.
  - `modules/networking` – Optional: Transit Gateway, VPC, private subnets (one per AZ), TGW VPC attachment, route table (0.0.0.0/0 → TGW). Used when `create_networking` is true.
- **GitHub Actions workflows** (`.github/workflows/`)
  - **deployment.yml** – Main deployment: plan/deploy/destroy the full stack (runners, ECS, EFS, and optionally networking). When `SHARED_CREATE_NETWORKING` is true, it creates the VPC, subnets, and TGW in the same run.
  - **deploy-networking.yml** – Optional: plan/deploy only the networking module using a **separate state file**. See [Deploy networking only](.github/workflows/deploy-networking-README.md) for details.
  - **docker-build.yml** – Build and push the runner Docker image to ECR. See [Docker build workflow](.github/workflows/docker-build-README.md).
- **Other** – `docker/` (Dockerfile), `scripts/` (e.g. IAM setup), `tests/` (Terraform test fixtures).

## Architecture

The following diagram shows the full picture: main architecture (VPC, subnets, ECS runners, EFS) together with network ingress and egress. We break it down below in separate diagrams and explanations.

```text
  Internet (GitHub, package registries, AWS APIs)
                    │
                    │  Egress: Runners send outbound (HTTPS, etc.); responses
                    │  return along the same path.
                    ▼
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  Transit Gateway (tgw-...). When create_networking = true we create the    │
  │  TGW, VPC, subnets, TGW attachment, and route (0.0.0.0/0 → TGW).            │
  └─────────────────────────────────────────────────────────────────────────────┘
                    │
                    │  Route: 0.0.0.0/0 → Transit Gateway
                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                AWS VPC                                           │
│  ┌──────────────────────────┐      ┌──────────────────────────┐                 │
│  │     Private Subnet       │      │     Private Subnet       │                 │
│  │  ┌─────────────────────┐  │      │  ┌─────────────────────┐  │                 │
│  │  │EC2 or Fargate (ECS) │  │      │  │EC2 or Fargate (ECS) │  │                 │
│  │  │  ┌──────────────┐   │  │      │  │  ┌──────────────┐   │  │                 │
│  │  │  │   Runner     │   │  │      │  │  │   Runner     │   │  │                 │
│  │  │  └──────────────┘   │  │      │  │  └──────────────┘   │  │                 │
│  │  └─────────────────────┘  │      │  └─────────────────────┘  │                 │
│  │            │              │      │            │              │                 │
│  │  ┌─────────────────────┐  │      │  ┌─────────────────────┐  │                 │
│  │  │     EFS Mount       │  │      │  │     EFS Mount       │  │                 │
│  │  └─────────────────────┘  │      │  └─────────────────────┘  │                 │
│  └────────────┬──────────────┘      └────────────┬──────────────┘                 │
│               └─────────────┬────────────────────┘                                 │
│                   ┌─────────────────┐                                             │
│                   │   EFS (KMS)      │                                             │
│                   └─────────────────┘                                             │
│  Ingress: none. Runners poll GitHub; no connections from the internet in.         │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### Main architecture (VPC, subnets, ECS runners, EFS)

This diagram shows what this repo deploys: a VPC and subnets (either your `vpc_id` and `subnets` or ones we create when `create_networking = true`), with ECS (EC2 or Fargate) running the GitHub runner in each subnet, each with an EFS mount to a single shared EFS filesystem.

```text
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                AWS VPC                                           │
│  ┌──────────────────────────┐      ┌──────────────────────────┐                 │
│  │     Private Subnet       │      │     Private Subnet       │                 │
│  │  ┌─────────────────────┐  │      │  ┌─────────────────────┐  │                 │
│  │  │EC2 or Fargate (ECS) │  │      │  │EC2 or Fargate (ECS) │  │                 │
│  │  │  ┌──────────────┐   │  │      │  │  ┌──────────────┐   │  │                 │
│  │  │  │   Runner     │   │  │      │  │  │   Runner     │   │  │                 │
│  │  │  └──────────────┘   │  │      │  │  └──────────────┘   │  │                 │
│  │  └─────────────────────┘  │      │  └─────────────────────┘  │                 │
│  │            │              │      │            │              │                 │
│  │  ┌─────────────────────┐  │      │  ┌─────────────────────┐  │                 │
│  │  │     EFS Mount       │  │      │  │     EFS Mount       │  │                 │
│  │  └─────────────────────┘  │      │  └─────────────────────┘  │                 │
│  └────────────┬──────────────┘      └────────────┬──────────────┘                 │
│               └─────────────┬────────────────────┘                                 │
│                   ┌─────────────────┐                                             │
│                   │   EFS (KMS)      │                                             │
│                   └─────────────────┘                                             │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**What this diagram is showing:**

- **AWS VPC (the big box)** – This is your private network (a logically isolated segment of AWS with its own IP address range (CIDR); resources in the VPC get private IPs and can route traffic to each other, and are isolated at the network level from other customers’ VPCs and from the public internet unless you add gateways or peering) in AWS. Everything in this setup lives inside it so it’s isolated and easier to secure.

- **Private Subnets (the two middle boxes)** – We use two separate subnets (each is a subdivision of the VPC’s IP range with its own CIDR block; traffic is routed between subnets, and placing resources in different subnets—often in different Availability Zones—gives you isolation and fault tolerance). That way if one has an issue, the other can still run. Runners are only in private subnets, so they’re not directly on the public internet.

- **EC2 or Fargate (ECS)** – Each box is a compute host: either an EC2 instance (a virtual machine: software-emulated computer with CPU, memory, and storage like a physical machine but running on AWS’s hardware) or a Fargate task (serverless container—no EC2 to manage). Both are managed by ECS (the service that runs your containers). On each one we run a **Runner** – the process that actually runs your GitHub Actions jobs.

- **EFS Mount** – Each EC2 instance (the ECS host in the diagram) has its own EFS mount – its own connection to the EFS filesystem. So each runner has its own mount; the thing that’s shared is the EFS itself. All those mounts point at the same EFS, so every runner can read and write the same files (e.g. runner config and cache) instead of each EC2 keeping a separate copy.

- **EFS (KMS)** at the bottom – That’s the one EFS filesystem. It’s encrypted with KMS so only your account can read the data. Every EC2 in both subnets mounts this same EFS, so their settings stay in sync and survive when a runner is replaced.

- **Network ingress/egress** – Runners sit in private subnets with no public IP. **Egress**: outbound traffic (to GitHub, AWS APIs, package registries) goes from runners to a **Transit Gateway** (your subnet route table sends 0.0.0.0/0 to tgw-...). **Ingress**: there is no inbound from the internet to the runners; security groups allow egress only, and runners poll GitHub for jobs instead of accepting incoming connections.

In short: you get multiple EC2 instances (runner hosts) in the subnets you provide (or we create when `create_networking = true`), each with its own mount to one shared, encrypted EFS so they can do work for GitHub Actions and stay in sync. They reach the internet via your VPC's egress (a route to a Transit Gateway); nothing can connect in to the runners from the internet.

#### Network ingress/egress (connecting to runners)

Egress uses a **Transit Gateway** only. To work out of the box, set **`create_networking = true`**: this repo creates the Transit Gateway, VPC, private subnets, TGW VPC attachment, and a route table that sends 0.0.0.0/0 to that TGW. Alternatively, **bring your own** VPC and subnets (with that route already set) and pass `vpc_id` and `subnets`. The diagram shows **egress** (outbound via TGW) and **ingress** (none to runners).

```text
  Internet (GitHub, package registries, AWS APIs)
                    │
                    │  Egress: Runners send outbound (HTTPS, etc.); responses
                    │  return along the same path.
                    ▼
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  Transit Gateway (tgw-...). When create_networking = true we create the    │
  │  TGW, VPC, subnets, TGW attachment, and route (0.0.0.0/0 → TGW).            │
  └─────────────────────────────────────────────────────────────────────────────┘
                    │
                    │  Route: 0.0.0.0/0 → Transit Gateway
                    ▼
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  VPC and subnets – runners, ECS, EFS                                         │
  │  When create_networking = true we create TGW, VPC, and subnets; otherwise     │
  │  use your vpc_id + subnets. Runners have only private IPs.                    │
  │  Ingress: none. Runners poll GitHub; no connections from the internet in.    │
  └─────────────────────────────────────────────────────────────────────────────┘
```

- **Egress:** Traffic from the subnets uses the route table’s 0.0.0.0/0 route to the Transit Gateway, then to the internet.
- **Ingress:** There is no path from the internet into the runners. Runners have no public IP and poll GitHub for jobs; security groups allow egress only.

#### Autoscaling and scale configuration

Scaling has two layers: (1) **EC2 host layer** (only when `launch_type = "EC2"`): an Auto Scaling Group plus an ECS Capacity Provider that can manage the ASG; (2) **Task layer**: each ECS service keeps a fixed number of runner tasks (`desired_count`). With **Fargate**, there is no ASG; scale is only the ECS service `desired_count`.

```text
  EC2 launch type:
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  ECS Capacity Provider (backed by ASG)                                      │
  │  • Managed scaling: ENABLED – ECS adjusts ASG desired capacity               │
  │  • Target capacity: 100% – ECS aims to keep capacity utilized                │
  │  • Managed termination protection: ENABLED – avoid terminating instances     │
  │    that are running tasks during scale-in                                    │
  └─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │  ECS drives ASG scale-up/scale-down
                                    ▼
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  Auto Scaling Group (EC2 container instances)                                │
  │  • min_size, max_size, desired_capacity (you set; ECS can change desired    │
  │    when managed scaling is on)                                              │
  │  • protect_from_scale_in: true (new instances protected until no tasks)     │
  │  • default_cooldown: 300 s                                                   │
  └─────────────────────────────────────────────────────────────────────────────┘

  Task layer (both EC2 and Fargate):
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  ECS Service (runner tasks)                                                  │
  │  • desired_count – number of runner tasks to keep running (per service)     │
  │  • deployment_minimum_healthy_percent – e.g. 100 = no scale-down during     │
  │    deployments                                                               │
  └─────────────────────────────────────────────────────────────────────────────┘
```

| Layer | Setting | Where | Effect |
|-------|---------|--------|--------|
| **EC2 host (ASG)** | `asg_min_size` | Variable (default `0`) | Minimum EC2 instances; `0` allows scale-to-zero. |
| **EC2 host (ASG)** | `asg_max_size` | Variable (default `5`) | Maximum EC2 instances; caps cost and scale-out. |
| **EC2 host (ASG)** | `asg_desired_capacity` | Variable (default `1`) | Target number of EC2 instances; ECS managed scaling can change this when enabled. |
| **EC2 capacity provider** | Managed scaling | `ecs.tf` (status `ENABLED`, `target_capacity = 100`) | ECS adjusts ASG desired capacity to keep utilization near 100%. |
| **EC2 capacity provider** | Managed termination protection | `ecs.tf` (`ENABLED`) | ECS avoids terminating instances that are running tasks during scale-in. |
| **ECS service** | `desired_count` | Variable / per service | Number of runner tasks to run; more = more concurrent jobs. |
| **ECS service** | `deployment_minimum_healthy_percent` | Variable (default `100`) | Minimum % of tasks healthy during deploy; `100` = no scale-down during rollout. |
| **Fargate** | No ASG | N/A | Scale is only via ECS service `desired_count`; Fargate adds/removes tasks. |

#### Third-party connectivity

The following diagram shows how components link to **third-party or external services** (outside your AWS account): GitHub for code and OIDC, AWS for deployment and runtime, and the public internet for package registries when workflow jobs run.

```text
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  GitHub (third party)                                                        │
  │  • github.com – repo, workflow triggers, runner list                          │
  │  • token.actions.githubusercontent.com – OIDC (workflows assume AWS role)    │
  └─────────────────────────────────────────────────────────────────────────────┘
        │                              │
        │ OIDC assume role              │ Register runner, poll jobs,
        │ (deploy / build workflows)    │ report status (HTTPS)
        ▼                              ▼
  ┌──────────────────────┐    ┌─────────────────────────────────────────────────┐
  │  AWS (your account)  │    │  Runners (in VPC, private subnets)               │
  │  • S3 – Terraform    │    │  • ECR – pull runner image (and optional base)   │
  │    state             │    │  • SSM Parameter Store – runner registration     │
  │  • ECS, EC2, EFS –   │◄───│    token                                          │
  │    deployment target │    │  • EFS, KMS, CloudWatch – runtime                 │
  │  • ECR – push runner │    │  • Outbound to internet – package registries     │
  │    image (build wf)  │    │    (npm, PyPI, Docker Hub, etc.) when jobs run   │
  └──────────────────────┘    └─────────────────────────────────────────────────┘
        │                                              │
        │                                              │ HTTPS (egress via Transit Gateway)
        │                                              ▼
        │                     ┌─────────────────────────────────────────────────┐
        │                     │  Internet – package registries (third party)     │
        │                     │  • npm, PyPI, Maven, Docker Hub, etc.            │
        │                     │  • Used by workflow jobs running on the runners  │
        │                     └─────────────────────────────────────────────────┘
```

| Link | Direction | Purpose |
|------|-----------|---------|
| **GitHub → AWS** | GitHub Actions workflow → OIDC → IAM role | Deploy (Terraform), build/push image (ECR); no long-lived AWS keys. |
| **GitHub ↔ Runners** | Runners → GitHub (HTTPS) | Register runner, poll for jobs, report status; runners initiate all calls. |
| **Runners → AWS** | Runners → ECR, SSM, EFS, CloudWatch, ECS | Pull image, read token, mount EFS, write logs, ECS agent. |
| **Runners → Internet** | Runners → public registries (egress) | Workflow jobs pull packages (npm, pip, Docker, etc.) via Transit Gateway. |

#### Permissions management

The following diagram shows how IAM roles, trust policies, and security groups are used for deployment (GitHub Actions → AWS) and for runtime (ECS tasks and EC2 container instances). Permissions are scoped by role; no long-lived AWS keys are stored in GitHub.

```text
  Deployment (GitHub Actions workflows) – created by scripts/setup-github-actions-iam.py
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  OIDC Provider: token.actions.githubusercontent.com                          │
  │  • Trust: GitHub issues JWT; AWS validates and allows AssumeRoleWithWebIdentity │
  └─────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        │  Trust: repo:org/repo:* (OIDC)
                                        ▼
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  GitHub Actions role (e.g. github-actions)                                   │
  │  • AssumeStateAndExec: can assume state-role + Terraform exec role            │
  │  • AdministratorAccess (for deploy/build workflows)                         │
  └─────────────────────────────────────────────────────────────────────────────┘
                    │                                    │
    assume          │                                    │  assume
    ────────────────┘                                    └────────────────
                    │                                    │
                    ▼                                    ▼
  ┌──────────────────────────────┐    ┌──────────────────────────────────────────┐
  │  State role                   │    │  Terraform exec role                     │
  │  • Trust: same AWS Org +      │    │  • Trust: GitHub Actions role only       │
  │    principal = GitHub Actions │    │  • AdministratorAccess (plan/apply)       │
  │  • S3: list/get/put/delete    │    │  • Used by deployment workflow for       │
  │    on TF state bucket         │    │    Terraform runs                         │
  └──────────────────────────────┘    └──────────────────────────────────────────┘

  Runtime (runners in ECS) – created by Terraform (runner_infra + runner_service)
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  EC2 container instances (when launch_type = EC2)                            │
  │  • Instance profile → instance role                                          │
  │  • Policies: AmazonEC2ContainerServiceforEC2Role, AmazonSSMManagedInstanceCore │
  │  • Used by: ECS agent, image pull, SSM Session Manager                       │
  └─────────────────────────────────────────────────────────────────────────────┘
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  ECS task (runner container) – execution role + task role (same role in repo) │
  │  • Trust: ecs-tasks.amazonaws.com                                            │
  │  • CloudWatch Logs (create stream, put events)                                │
  │  • ECR (GetAuthorizationToken, BatchGetImage, etc.)                           │
  │  • SSM (GetParameter – runner token; ssmmessages – ECS Exec)                 │
  │  • EFS (ClientMount, ClientWrite) + KMS decrypt (ViaService = EFS)           │
  │  • Optional: sts:AssumeRole / sts:TagSession for workflow-assumed roles      │
  └─────────────────────────────────────────────────────────────────────────────┘
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  Security groups (network layer)                                             │
  │  • Runner tasks SG: egress only (0.0.0.0/0) – outbound to GitHub, AWS, etc.  │
  │  • EFS SG: ingress NFS (2049) from runner tasks SG only                        │
  └─────────────────────────────────────────────────────────────────────────────┘
```

| Scope | Role / resource | Trust | Key permissions |
|-------|------------------|--------|------------------|
| **Deploy** | GitHub Actions role | OIDC (repo:org/repo) | Assume state + Terraform exec; AdministratorAccess |
| **Deploy** | State role | Same org + GitHub Actions role ARN | S3 state bucket (list, get, put, delete) |
| **Deploy** | Terraform exec role | GitHub Actions role | AdministratorAccess (plan/apply) |
| **Runtime** | EC2 instance role | ec2.amazonaws.com | ECS for EC2, SSM Managed Instance Core |
| **Runtime** | ECS task role | ecs-tasks.amazonaws.com | CloudWatch Logs, ECR pull, SSM (token + ECS Exec), EFS + KMS, optional STS assume |

## What You Need Before Starting

Before you begin, make sure you have:

1. **An AWS Account** - You'll need access to create resources. In most cases, your client/team provides this (or gives you a sandbox account). If you were not given an account, create one here: https://signin.aws.amazon.com/signup?request_type=register
2. **AWS CLI Installed** - A tool to talk to AWS from your computer
   - Download: https://aws.amazon.com/cli/
   - After installing, run: `aws configure` to set up your credentials
3. **Terraform Installed** - A tool that creates AWS resources for you
   - Download: https://www.terraform.io/downloads
   - Version 1.0 or newer
4. **Docker Installed** - To build the runner image
   - Download: https://www.docker.com/get-started
5. **GitHub Access** - Admin access to the GitHub organization or repository where you want to add runners
6. **A VPC in AWS** - A virtual network (we'll help you check this), or use create networking so the repo creates it

## Step-by-Step Setup Guide

Follow these steps in order. Don't skip ahead - each step depends on the previous one!

### Step 0: Fork the Repository (and When to Use a Branch)

**Goal:** You should be able to **fork this repository**, fill in your own GitHub **Secrets** and **Variables**, and run the included GitHub Actions workflows to validate everything works.

To implement this GitHub runner, all you have to do is fork the repo, add the GitHub variables and secrets, and test them in Actions for the two workflows.

**Forking:**
- Fork this repository into your own GitHub org/user.
- Do your setup work (Secrets/Variables) in **your fork**.

**When you need a branch:**
- **You do not need a branch** just to configure GitHub Secrets/Variables (those are repo settings).
- **You do need a branch** if you want to change code/config in the repo (Terraform files, module logic, workflow YAML, Dockerfile, README, etc.).

**How to create a branch (recommended workflow):**
1. In your fork, create a branch off your default branch (for example: `setup` or `feature/my-change`).
2. Make and commit your changes to that branch.
3. In the GitHub Actions UI, select **Run workflow → Use workflow from** and pick your branch when testing changes.
4. When you’re happy, open a PR in your fork (and optionally merge it into your default branch).

### Step 1: Get Your AWS Account Information

You'll need two pieces of information from AWS:

If your organization uses the **AWS Access Portal**, that is how you choose/sign in to an account. Once you open an account in the browser, the website UI you are using is the **AWS Console** (same thing in this README).

1. **Your AWS Account ID** - A 12-digit number
   - Find it: Log into AWS Console → Click your username (top right) → The account ID is shown there
   - If it is not shown in the top-right menu for your login/session, get it from the AWS Access Portal account tile/details for the account you opened.
   - Or run: `aws sts get-caller-identity --query Account --output text`

2. **Your AWS Region** - Where you want to create everything (e.g., `us-east-1`, `us-west-2`, `eu-west-1`)
   - This is usually shown in the top-right of the AWS Console
   - Common regions: `us-east-1` (N. Virginia), `us-west-2` (Oregon), `eu-west-1` (Ireland)

   On which region to use: users should pick the region where they are allowed to deploy and where their dependencies live.

   Practical guidance:
   - Start with the region your client/platform team specifies (best source of truth).
   - Use the same region consistently for:
     - IAM role assumption scope
     - Terraform backend bucket access
     - ECR image location
     - VPC/networking resources
   - Set that as `SHARED_AWS_REGION` (and check Console selector + CloudShell context matches).

   Quick checks:
   - Console region selector (top-right) should match `SHARED_AWS_REGION`.
   - CloudShell:
     ```bash
     aws sts get-caller-identity --query Account --output text
     aws configure get region
     ```
   - If they pick the wrong region, they’ll often see “not authorized”/resource-not-found style errors even when permissions look correct.

   **If there is no client-provided region, use this quick guide:**
   1. Use your team/client standard region first (if one exists).
   2. If no standard is provided, choose one region and keep all resources in that same region.
   3. Prefer a region where your account has permissions and required services available.
      - Using the wrong region can produce misleading permission/resource errors even when your setup is otherwise correct.
   Run this first: confirm account and region context in CLI:
   ```bash
   aws sts get-caller-identity --query Account --output text
   aws configure get region
   ```
   4. Confirm service availability in that region:
      - Check AWS Regional Services list: https://aws.amazon.com/about-aws/global-infrastructure/regional-product-services/
      - Verify the core services used here (ECS, EC2/VPC, ECR, EFS, SSM, IAM, CloudWatch Logs, S3 backend access) are available in your chosen region.
   5. Confirm permissions in that region before deployment (easy mode in CloudShell):
      - Set your region once:
        ```bash
        REGION=us-east-1
        ```
      - Run these checks:
        ```bash
        aws sts get-caller-identity --output table
        aws ec2 describe-vpcs --region $REGION --max-items 5
        aws ecs list-clusters --region $REGION --max-items 5
        aws ecr describe-repositories --region $REGION --max-items 5
        aws efs describe-file-systems --region $REGION --max-items 5
        aws ssm describe-parameters --region $REGION --max-results 5
        aws s3api list-buckets --max-items 20
        aws ec2 create-vpc --region $REGION --cidr-block 10.255.0.0/16 --dry-run
        ```
      - What success looks like:
        - Read/list commands return data (or empty lists).
        - Dry run returns `DryRunOperation`.
      - If a check fails:
        - `AccessDenied` or `UnauthorizedOperation`: ask your AWS admin/platform team to grant permissions in this account/region.
        - `explicit deny in a service control policy`: this is an org-level block (SCP). Only org/security admins can change it.
        - Endpoint/region errors: verify your region and retry with the correct value.
      - Optional deeper check: IAM Policy Simulator (https://policysim.aws.amazon.com/) can test specific actions on a role/user.

**Write these down** - you'll need them in later steps!

### Step 2: Understand the Deployment Workflows

You will run **Build & Push Docker Image** before you run **Multi-Org github runner Deployment**. Before both workflows, run the Python IAM setup script (`scripts/setup-github-actions-iam.py`) once to create/update the GitHub OIDC role and related IAM setup (here is how to run it: [scripts/README.md](scripts/README.md)), then add those outputs as repository secrets/variables. Those values are explained in the next section. For now, here is what each workflow is, what it does, and why it is important.

There are three workflows plus one required setup script you will use during setup and deployment:

1. **Python IAM Setup Script** (`scripts/setup-github-actions-iam.py`) – Creates/updates the AWS OIDC provider and IAM roles used by GitHub Actions. **Why it matters:** workflows cannot assume AWS roles without this setup. **When to run:** once before running workflows (or again if you need to update IAM settings). How to run: [scripts/README.md](scripts/README.md).
2. **Build & Push Docker Image** (`.github/workflows/docker-build.yml`) – Builds the runner Docker image from `docker/dockerfile` and pushes it to ECR. **Why it matters:** `deployment.yml` needs a valid image URI (`SHARED_RUNNER_IMAGE`) to start runner tasks. **When to run:** first-time setup after running python iam setup script and before running the multi-org github runner deployment workflow, and any time you change Docker image content. See [.github/workflows/docker-build-README.md](.github/workflows/docker-build-README.md).
3. **Multi-Org github runner Deployment** (`.github/workflows/deployment.yml`) – Main infrastructure workflow that runs Terraform plan/deploy/destroy for ECS runners, EFS, IAM, and optional networking. **Why it matters:** this is the workflow that actually creates and updates your runner platform. **When to run:** after required secrets/variables are configured and after build & push docker image workflow runs.
4. **Deploy networking only** (`.github/workflows/deploy-networking.yml`) – Optional Terraform workflow focused only on networking resources (VPC, subnets, TGW) using a separate state key. **Why it matters:** lets you test or manage networking independently from the full deployment. **When to run:** when validating networking in isolation or when you want networking changes separately controlled. See [.github/workflows/deploy-networking-README.md](.github/workflows/deploy-networking-README.md).

**What the workflow needs:**

The workflow requires you to set up GitHub repository secrets and variables. Here's what you'll need to collect, with detailed explanations:

**GitHub Secrets (sensitive information):**

| Secret Name | Example Value | Why You Need This | Where to Get This |
|------------|---------------|-------------------|-------------------|
| `SHARED_AWS_ACCOUNT_ID` | `123456789012` | Used to construct ARNs and assume IAM roles. The workflow needs this to authenticate with AWS using OIDC. | See Step 1 for instructions. |
| `SHARED_VPC_ID` | `vpc-0123456789abcdef0` | VPC ID for runner deployment when **bring your own networking** is used (`SHARED_CREATE_NETWORKING=false`). | See Step 3 for instructions. Not needed when `SHARED_CREATE_NETWORKING=true`. |
| `SHARED_SUBNETS` | `subnet-0123456789abcdef0,subnet-0fedcba9876543210` | Subnet IDs for runner deployment when **bring your own networking** is used (`SHARED_CREATE_NETWORKING=false`). | See Step 3 for instructions. Not needed when `SHARED_CREATE_NETWORKING=true`. |
| `SHARED_SECURITY_GROUP_IDS` | `sg-0123456789abcdef0` | Security groups act as virtual firewalls controlling inbound and outbound traffic. The runners need appropriate security group rules to communicate with GitHub, AWS services, and your internal resources. | See Step 3 for instructions. If you need to create new security groups, ask your AWS administrator or security team about the required rules (typically: outbound HTTPS to GitHub, outbound HTTPS to AWS APIs, and any internal network access needed). |
| `SHARED_RUNNER_SERVICE_NAME` | `default`, `production-runners`, `team-a-runners` | This is an identifier for your ECS service. It helps organize multiple runner services if you deploy runners for different teams or environments. Choose a descriptive name that makes sense for your organization. | Pick a name that describes the purpose (e.g., `default` for a single service, `prod-runners` for production, `dev-runners` for development). This is just a label - you decide what makes sense. |
| `SHARED_GITHUB_ORG` | `my-company`, `acme-corp`, `engineering-team` | This tells the runner which GitHub organization to register with. The runner will appear in that organization's runner list and can execute workflows for repositories in that org. | This is the name that appears in your GitHub organization URL: `https://github.com/YOUR_ORG_NAME`. If you're deploying for a repository instead of an organization, you may need to check with your GitHub administrator about the correct value. |
| `SHARED_RUNNER_TOKEN_SSM_PARAMETER_NAME` | `github-runner/token`, `/github/runners/prod/token`, `my-org/github-runner-token` | This is the path/name in AWS Systems Manager Parameter Store where you'll store the GitHub runner registration token. The runners will retrieve this token at startup to authenticate with GitHub. | Use a hierarchical naming convention that makes sense (e.g., `github-runner/token` for simple setups, or `/github/runners/environment/token` for multiple environments). The parameter name you choose here must match what you use in Step 5. |
| `SHARED_AWS_ROLE_NAME` | `GitHubActionsTerraformRole`, `github-actions-deploy-role`, `terraform-deployment-role` | This IAM role allows the GitHub Actions workflow to authenticate with AWS using OpenID Connect (OIDC) without storing long-lived credentials. The workflow assumes this role to run Terraform commands. | If this role doesn't exist yet, you'll need to create it or ask your AWS administrator/DevOps team to create it. The role needs permissions to create/manage ECS, EC2, VPC, IAM, and other resources. If you're unsure, ask your AWS administrator - they should know if a role already exists for GitHub Actions deployments. |
| `TF_BACKEND_BUCKET` | `my-company-terraform-state`, `github-runner-terraform-state`, `infrastructure-state-bucket` | Terraform needs to store its state file (which tracks what resources it has created) in a shared location. This bucket stores that state so multiple runs of the workflow can see what already exists. | If this bucket doesn't exist, you'll need to create it or ask your AWS administrator. The bucket should have versioning enabled and be in the same region as your deployment. Ask your DevOps/Infrastructure team if there's a standard Terraform state bucket you should use. |

**GitHub Variables (non-sensitive configuration):**

| Variable Name | Example Value | Why You Need This | Where to Get This |
|--------------|---------------|-------------------|-------------------|
| `SHARED_AWS_REGION` | `us-east-1`, `us-west-2`, `eu-west-1`, `ap-southeast-2` | All AWS resources (ECS cluster, EC2 instances, etc.) will be created in this region. Choose a region close to your users or that meets compliance requirements. | See Step 1 for instructions. If unsure, ask your AWS administrator about your organization's preferred region. |
| `TF_STATE_KEY` | `github-runner/terraform.tfstate` | S3 object key used by `deployment.yml` Terraform backend state. Must be different from `TF_NETWORKING_STATE_KEY` if you also use `deploy-networking.yml`. | Pick a unique path in your state bucket (for example per env/account). |
| `SHARED_CREATE_NETWORKING` | `true` or `false` | Controls networking mode in `deployment.yml`: `true` creates VPC/subnets/TGW; `false` uses `SHARED_VPC_ID`/`SHARED_SUBNETS`. | Set based on your deployment mode. |
| `SHARED_VPC_CIDR` | `10.40.0.0/16` | Primary VPC CIDR when `SHARED_CREATE_NETWORKING=true`. | Choose a private non-overlapping CIDR (`/16` to `/28` for primary VPC CIDR). |
| `SHARED_VPC_ADDITIONAL_CIDRS` | `["10.41.0.0/16"]` | Optional additional VPC CIDRs when `SHARED_CREATE_NETWORKING=true`. | Optional JSON array; use `[]` or leave unset if not needed. |
| `SHARED_NETWORKING_AZS` | `["us-east-1a","us-east-1d"]` | AZ list for subnet creation when `SHARED_CREATE_NETWORKING=true`. | Pick at least 2 AZs in your region; must be valid JSON array. |
| `SHARED_RUNNER_IMAGE` | `123456789012.dkr.ecr.us-east-1.amazonaws.com/github-runner:latest` | This is the Docker image that contains the GitHub Actions runner software. ECS will pull this image and run it as containers on your EC2 instances. | See Step 6 for instructions. The format is: `ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/REPOSITORY_NAME:TAG` |
| `SHARED_DESIRED_COUNT` | `1`, `2`, `5` | This controls how many runner containers will be running simultaneously. More runners = more workflows can run in parallel, but also higher AWS costs. Start with 1 and increase if you need more parallel capacity. | Consider your typical workflow load. If you have many concurrent workflows, you may need 2-5 runners. If workflows run sequentially, 1 is usually sufficient. You can always change this later and redeploy. |
| `SHARED_DEPLOYMENT_MIN_HEALTHY_PERCENT` | `100` | Optional ECS deployment setting used in `runner_services`. Defaults to `100` if unset. | Optional tuning value. |
| `SHARED_DEPLOYMENT_MAXIMUM_PERCENT` | `200` | Optional ECS deployment setting used in `runner_services`. Defaults to `200` if unset. | Optional tuning value. |
| `SHARED_RUNNER_NAME_PREFIX` | `ecs-github-runner`, `aws-runner-prod`, `team-a-runner` | This prefix appears in the GitHub runner list to help identify your runners. GitHub will append a unique identifier, so you'll see names like `ecs-github-runner-abc123`. | Pick something descriptive that helps you identify these runners in GitHub's UI. Include environment or team info if you have multiple sets of runners (e.g., `prod-runner`, `dev-runner`). |
| `SHARED_RUNNER_LABELS` | `self-hosted,team-a,ecs,ec2`, `self-hosted,linux,x64,production` | Labels allow you to target specific runners in your GitHub Actions workflows using `runs-on: [label1, label2]`. You can use labels to route workflows to specific runner types, teams, or environments. | Include `self-hosted` (required by GitHub), plus descriptive labels like team names, environment (prod/dev), or capabilities (docker, large, etc.). Common labels: `self-hosted`, `linux`, `x64`, plus your custom labels. Think about how you want to organize workflow routing. |
| `SHARED_INSTANCE_AMI` | `ami-0123456789abcdef0` (this will be different for each region) | This is the Amazon Machine Image (operating system) that will run on your EC2 instances. The ECS-optimized AMI is pre-configured with Docker and the ECS agent needed to run containers. | See Step 8 for instructions on finding the correct AMI. The AMI ID is different for each region, so make sure you get the one for your specific region. If you're unsure, ask your AWS administrator or use the AWS documentation link provided in Step 8. |
| `SHARED_CLUSTER_NAME` | `nexus-repo` | Optional cluster/resource naming value used by the workflows. Defaults to `nexus-repo` if unset. | Optional; set only if you want a custom name. |

**What this means:** In the next steps, you'll gather all these values. Then in Step 8, you'll add them to your GitHub repository settings. The workflow will automatically use them when you deploy.

### Step 3: Set Up Your VPC (Virtual Network)

A VPC is like a private network in AWS. You need one with:

1. **At least 2 Private Subnets** - These are like separate rooms in your network
   - Find your VPC: AWS Console → VPC → Your VPCs
   - Find your subnets: AWS Console → VPC → Subnets
   - Write down the VPC ID (looks like `vpc-12345678`) and at least 2 subnet IDs (look like `subnet-12345678`)

2. **DNS Enabled** - This lets your runners find things on the internet
   - Check if enabled: AWS Console → VPC → Your VPCs → Select your VPC → Check "DNS hostnames" and "DNS resolution"
   - If not enabled, run these commands (replace `vpc-12345678` with your VPC ID):
     ```bash
     aws ec2 modify-vpc-attribute --vpc-id vpc-12345678 --enable-dns-hostnames
     aws ec2 modify-vpc-attribute --vpc-id vpc-12345678 --enable-dns-support
     ```

**Don't have a VPC?** Ask your AWS administrator to create one, or create a simple one in the AWS Console (VPC → Create VPC). If you use **create networking** (`SHARED_CREATE_NETWORKING` = `true`), you can skip this step—the repo will create the VPC and subnets for you.

**Why you need this:** The deployment workflow needs your VPC ID, subnet IDs, and security group IDs for the `SHARED_VPC_ID`, `SHARED_SUBNETS`, and `SHARED_SECURITY_GROUP_IDS` secrets you'll set up in Step 8.

### Step 4: Get a GitHub Runner Token

This token lets your runner connect to GitHub. Here's how to get it:

1. Go to your GitHub organization or repository
2. Click **Settings** (at the top of the page)
3. Click **Actions** (in the left sidebar)
4. Click **Runners** (in the left sidebar)
5. Click **New self-hosted runner** (green button)
6. Select **Linux** for the operating system (runners run in AWS ECS, which uses Linux containers)
7. Select **x64** for the architecture (matches EC2 t3 instances and ECS-optimized AMIs)
8. Copy the token shown after `--token` in the **Configure** section (in the command `./config.sh --url ... --token YOUR_TOKEN_HERE`; copy the `YOUR_TOKEN_HERE` value)

> ⚠️ **IMPORTANT**: This token expires in 1 hour! If you take longer than an hour to finish setup, you'll need to get a new token.

**Write this token down** - you'll use it in the next step!

**Why you need this:** The deployment workflow needs a runner token stored in AWS SSM Parameter Store. The parameter name you choose will be used for the `SHARED_RUNNER_TOKEN_SSM_PARAMETER_NAME` secret in Step 8.

### Step 5: Save the Token Securely in AWS

We'll store your GitHub token in AWS Systems Manager Parameter Store (think of it as a secure password vault).

Add the Token to GitHub (Automated AWS Write)
Instead of manually writing the token to AWS, we now store it as a GitHub secret and let the deployment workflow write it to AWS Systems Manager Parameter Store automatically.
Go to your GitHub repository
Click Settings
Click Secrets and variables → Actions
Click New repository secret
Name the secret:
SHARED_RUNNER_TOKEN
Paste the token you copied in Step 4
Click Save


**What this does:** Saves your token securely in AWS so the runners can use it later.

**Important:** Remember the parameter name you used (e.g., `github-runner/token`) - you'll need it for the `SHARED_RUNNER_TOKEN_SSM_PARAMETER_NAME` secret in Step 8.

### Step 6: Build and Upload the Runner Docker Image

A Docker image is like a package that contains everything the runner needs to work. We'll build it and upload it to AWS.

**Option A (recommended): Use GitHub Actions to build & push the image**

This repository includes a workflow at `.github/workflows/docker-build.yml` named **Build & Push Docker Image**.

1. Go to your fork → **Actions**
2. Select **Build & Push Docker Image**
3. Click **Run workflow**
4. Choose the branch you want to run it from
5. For **Docker image tag**, type `latest`
6. Click the green **Run workflow** button

If it runs successfully, the workflow will turn green and your ECR repository will have a new image tag.
If it turns red, see **Troubleshooting workflow failures** below.

**Option B: Build locally and push to ECR (manual)**

**First, create a place to store the image (ECR Repository):**

```bash
aws ecr create-repository \
  --repository-name github-runner \
  --region YOUR_AWS_REGION
```

**Then, log into AWS's Docker registry:**

```bash
aws ecr get-login-password --region YOUR_AWS_REGION | \
  docker login --username AWS --password-stdin YOUR_ACCOUNT_ID.dkr.ecr.YOUR_AWS_REGION.amazonaws.com
```

**Now, build and upload the image:**

```bash
# Go to the docker folder
cd docker/

# Build the image
docker build -t github-runner:latest .

# Tag it (give it a name AWS can find)
docker tag github-runner:latest YOUR_ACCOUNT_ID.dkr.ecr.YOUR_AWS_REGION.amazonaws.com/github-runner:latest

# Upload it to AWS
docker push YOUR_ACCOUNT_ID.dkr.ecr.YOUR_AWS_REGION.amazonaws.com/github-runner:latest
```

**What to replace:**
- `YOUR_ACCOUNT_ID` - The 12-digit number from Step 1
- `YOUR_AWS_REGION` - The region from Step 1

**What this does:** Creates a package with the runner software and uploads it to AWS so your runners can use it.

**Important:** The full image path (e.g., `123456789012.dkr.ecr.us-east-1.amazonaws.com/github-runner:latest`) will be used for the `SHARED_RUNNER_IMAGE` variable in Step 8.

### Step 7: Create Infrastructure Config File

Create or edit the file `env/multi-org.tfvars` (it's in the `env` folder). This file contains only the basic infrastructure settings that don't change between environments:

```hcl
# Shared infra (one ECS cluster + one ASG capacity provider)
cluster_name   = "nexus-repo"
create_cluster = false

launch_type = "EC2"

instance_type        = "t3.medium"
asg_min_size         = 0
asg_max_size         = 5
asg_desired_capacity = 1

# Docker prune cron job (runs hourly, removes resources older than 3h)
enable_docker_prune_cron = true
docker_prune_cron_schedule = "0 * * * *"
docker_prune_until = "3h"
docker_volume_size = 100
```

**What this does:** This file provides infrastructure-level settings (like cluster name, instance types, etc.) that the deployment workflow will use along with your GitHub secrets and variables.

### Step 8: Set Up GitHub Secrets and Variables

Now that you've gathered all the information from the previous steps, add them to your GitHub repository settings. The deployment workflow will automatically use these when you deploy.

**How to add secrets and variables:**
1. Go to your GitHub repository
2. Click **Settings** (at the top of the repository page)
3. Click **Secrets and variables** → **Actions** in the left sidebar
4. Use the **Secrets** tab for sensitive information
5. Use the **Variables** tab for non-sensitive configuration

**1. Set up GitHub Repository Secrets**

Go to your GitHub repository → **Settings** → **Secrets and variables** → **Actions** → **Secrets** tab, and add these secrets using the values you collected:

| Secret Name | What to Enter | Example Value | Why You Need This | Where You Got This |
|------------|---------------|---------------|-------------------|-------------------|
| `SHARED_AWS_ACCOUNT_ID` | Your 12-digit AWS account ID | `123456789012` | Used by the workflow to construct AWS ARNs and assume IAM roles for authentication | **Step 1** - Found in AWS Console or via `aws sts get-caller-identity` |
| `SHARED_VPC_ID` | Your VPC ID | `vpc-0123456789abcdef0` | Required only when **bring your own networking** is used (`SHARED_CREATE_NETWORKING=false`) | **Step 3** - Found in AWS Console (VPC → Your VPCs). Leave unset when `SHARED_CREATE_NETWORKING=true` |
| `SHARED_SUBNETS` | Comma-separated subnet IDs (no spaces) | `subnet-0123456789abcdef0,subnet-0fedcba9876543210` | Required only when **bring your own networking** is used (`SHARED_CREATE_NETWORKING=false`) | **Step 3** - Found in AWS Console (VPC → Subnets). Leave unset when `SHARED_CREATE_NETWORKING=true` |
| `SHARED_SECURITY_GROUP_IDS` | Comma-separated security group IDs (no spaces) | `sg-0123456789abcdef0` | Controls network traffic rules (firewall) for the runners. Must allow outbound HTTPS to GitHub and AWS APIs | **Step 3** - Found in AWS Console (VPC → Security Groups). If you need to create new ones, ask your security team about required rules |
| `SHARED_RUNNER_SERVICE_NAME` | A name for your runner service | `default` or `production-runners` | Identifies this ECS service. Used for organization if you have multiple runner services | **You choose this** - Pick a descriptive name. Common: `default`, `prod-runners`, `dev-runners`, `team-a-runners` |
| `SHARED_GITHUB_ORG` | Your GitHub organization name | `my-company` or `acme-corp` | The GitHub organization where runners will register and appear. Must match your org's URL name | **Your GitHub org** - Found in your GitHub org URL: `https://github.com/YOUR_ORG_NAME`. If deploying for a repo, check with your GitHub admin |
| `SHARED_RUNNER_TOKEN_SSM_PARAMETER_NAME` | The SSM parameter path/name | `github-runner/token` or `/github-org/runner/token` | The path in AWS Parameter Store where the GitHub runner token is stored. Runners retrieve this to authenticate | **Step 5** - The parameter name you used when storing the token (e.g., `github-runner/token`) |
| `SHARED_AWS_ROLE_NAME` | IAM role name for GitHub Actions | `GitHubActionsTerraformRole` or `github-actions-deploy-role` | Allows GitHub Actions workflow to authenticate with AWS via OIDC (no long-lived credentials needed) | **Ask your AWS admin** - This role must exist and have permissions to create ECS, EC2, VPC, IAM resources. If it doesn't exist, ask your DevOps/Infrastructure team to create it |
| `TF_BACKEND_BUCKET` | S3 bucket name for Terraform state | `my-company-terraform-state` or `github-runner-terraform-state` | Stores Terraform's state file so the workflow knows what resources already exist. Must have versioning enabled | **Ask your DevOps team** - Check if your organization has a standard Terraform state bucket. If not, create one or ask your AWS administrator. Should be in the same region as your deployment |

**2. Set up GitHub Repository Variables**

Go to **Settings** → **Secrets and variables** → **Actions** → **Variables** tab, and add these variables:

| Variable Name | What to Enter | Example Value | Why You Need This | Where You Got This |
|--------------|---------------|---------------|-------------------|-------------------|
| `SHARED_AWS_REGION` | Your AWS region code | `us-east-1`, `us-west-2`, `eu-west-1` | All AWS resources will be created in this region. Choose based on proximity to users or compliance requirements | **Step 1** - Found in AWS Console top-right, or ask your AWS administrator about your org's preferred region |
| `TF_STATE_KEY` | Terraform state key path used by deployment workflow | `github-runner/terraform.tfstate` | Backend state key used by `deployment.yml`; keep distinct from `TF_NETWORKING_STATE_KEY` used by networking-only workflow | **You choose this** - Use a unique key path per account/environment |
| `SHARED_CREATE_NETWORKING` | `true` to create networking, `false` to use existing VPC/subnets | `true` | Controls mode in `deployment.yml` | **You choose this** - Set `true` for out-of-box networking creation |
| `SHARED_VPC_CIDR` | Primary VPC CIDR (`/16` to `/28`) | `10.40.0.0/16` | Required when `SHARED_CREATE_NETWORKING=true` | **Step 8 networking guidance below** |
| `SHARED_VPC_ADDITIONAL_CIDRS` | Optional JSON array of additional VPC CIDRs | `["10.41.0.0/16"]` | Optional when `SHARED_CREATE_NETWORKING=true` for extra address space | **Step 8 networking guidance below** |
| `SHARED_NETWORKING_AZS` | JSON array of AZ names | `["us-east-1a","us-east-1d"]` | Required when `SHARED_CREATE_NETWORKING=true`; used to create one subnet per AZ | **Step 8 networking guidance below** |
| `SHARED_RUNNER_IMAGE` | Full ECR image URI | `123456789012.dkr.ecr.us-east-1.amazonaws.com/github-runner:latest` | The Docker image containing the GitHub Actions runner software. ECS pulls this to run your runners | **Step 6** - The full image path after building and pushing to ECR. Format: `ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/REPOSITORY:TAG` |
| `SHARED_DESIRED_COUNT` | Number of runners (as a number) | `1`, `2`, or `5` | How many runner containers to run simultaneously. More = more parallel workflows but higher cost | **You choose this** - Start with `1` for testing. Increase to 2-5 if you need more parallel capacity. Can change later |
| `SHARED_DEPLOYMENT_MIN_HEALTHY_PERCENT` | Optional minimum healthy percent | `100` | Optional ECS deployment control; defaults to `100` if unset | **Optional** |
| `SHARED_DEPLOYMENT_MAXIMUM_PERCENT` | Optional maximum percent | `200` | Optional ECS deployment control; defaults to `200` if unset | **Optional** |
| `SHARED_RUNNER_NAME_PREFIX` | Prefix for runner names | `ecs-github-runner`, `aws-runner-prod`, `team-a-runner` | Appears in GitHub's runner list to identify your runners. GitHub adds a unique suffix | **You choose this** - Pick something descriptive. Examples: `ecs-github-runner`, `prod-runner`, `team-a-runner`. Include environment/team info if you have multiple sets |
| `SHARED_RUNNER_LABELS` | Comma-separated labels (no spaces after commas) | `self-hosted,team-a,ecs,ec2` or `self-hosted,linux,x64,production` | Used in `runs-on:` in workflows to target specific runners. Allows routing workflows to specific runner types | **You choose this** - Must include `self-hosted`. Add descriptive labels like team names, environment, or capabilities. Examples: `self-hosted,linux,x64,prod` or `self-hosted,team-a,docker,large` |
| `SHARED_INSTANCE_AMI` | ECS-optimized AMI ID for your region | `ami-0123456789abcdef0` (varies by region) | The operating system image for EC2 instances. ECS-optimized AMI has Docker and ECS agent pre-installed | **See instructions below** - AMI ID is different for each region. Use the latest ECS-optimized AMI for your specific region |
| `SHARED_CLUSTER_NAME` | Optional cluster/resource name | `nexus-repo` | Optional naming value used by workflow; defaults to `nexus-repo` if unset | **Optional** |

**3. Optional: Create networking (VPC, subnets, Transit Gateway)**

If you want this repo to **create** the VPC, private subnets, **Transit Gateway**, VPC attachment to the TGW, and route(s) (so runner egress goes via the TGW), set the following. Nothing is passed in: the repo creates the Transit Gateway as well as the VPC and subnets. When this option is enabled, you do **not** set `SHARED_VPC_ID` or `SHARED_SUBNETS` (Terraform creates them and the TGW).

**How to set them:** In the same place as above — **Settings** → **Secrets and variables** → **Actions** → **Variables** tab. All of these are non-sensitive (CIDR, AZs, a flag); no secrets are required for create-networking, so nothing needs to be hidden from the repo.

**Keeping the repo safe for public use:** Do not put real account IDs, VPC IDs, or subnet IDs in this repository or in repo Variables (they are visible to anyone with read access). Put resource IDs and other sensitive values in **Secrets**. When you use create-networking, the Transit Gateway is created by Terraform so there is no TGW ID to pass in or store. The README and docs use only generic examples (e.g. `10.0.0.0/16`, `us-east-1a`); your actual values live only in GitHub Secrets and in your deployed AWS resources.

| Name | Tab | What to Enter | Example | When |
|------|-----|---------------|---------|------|
| `SHARED_CREATE_NETWORKING` | **Variables** | `true` to create VPC, subnets, Transit Gateway, attachment, and routes | `true` | Required when you want the repo to create networking. Omit or set `false` when using your own VPC/subnets. |
| `SHARED_VPC_CIDR` | **Variables** | Primary CIDR block for the created VPC. AWS VPC primary CIDRs must be between `/16` and `/28`. Use a private range that does not overlap with other networks you need to reach. | `10.40.0.0/16` | Required when creating networking so Terraform knows the primary VPC CIDR. |
| `SHARED_VPC_ADDITIONAL_CIDRS` | **Variables** | Optional JSON array of additional VPC CIDRs to associate after VPC creation. Use this when you want more address space (for example a second `/16`). | `["10.41.0.0/16"]` | Optional. Set to `[]` or leave unset if you only want one CIDR block. |
| `SHARED_NETWORKING_AZS` | **Variables** | JSON array of availability zone names (e.g. two AZs in your region) so subnets are created in each. Ensures runners span AZs for availability. | `["us-east-1a","us-east-1d"]` | Required when creating networking. Must be valid JSON; region AZ codes are generic and safe for public repos. |

### Minimum required for `deployment.yml` (out-of-box run)

Use this checklist when testing **Multi-Org github runner Deployment** (`.github/workflows/deployment.yml`).

Required **Secrets**:

- `SHARED_AWS_ACCOUNT_ID`
- `SHARED_AWS_ROLE_NAME`
- `TF_BACKEND_BUCKET`
- `SHARED_RUNNER_SERVICE_NAME`
- `SHARED_GITHUB_ORG`
- `SHARED_RUNNER_TOKEN_SSM_PARAMETER_NAME`

Required **Variables**:

- `SHARED_AWS_REGION`
- `TF_STATE_KEY`
- `SHARED_RUNNER_IMAGE`
- `SHARED_DESIRED_COUNT`
- `SHARED_RUNNER_NAME_PREFIX`
- `SHARED_RUNNER_LABELS`
- `SHARED_INSTANCE_AMI` (required for EC2 launch type in this repo/workflow)

If `SHARED_CREATE_NETWORKING=true`, also set:

- `SHARED_CREATE_NETWORKING=true`
- `SHARED_VPC_CIDR`
- `SHARED_NETWORKING_AZS`
- Optional: `SHARED_VPC_ADDITIONAL_CIDRS` (JSON array, default `[]`)

When `SHARED_CREATE_NETWORKING=true`, you do **not** need:

- `SHARED_VPC_ID`
- `SHARED_SUBNETS`

### How to choose `SHARED_VPC_CIDR`

Choose a CIDR that is valid for your environment, not just a doc example.

Rules:

- Use a private RFC1918 range (`10.0.0.0/8`, `172.16.0.0/12`, or `192.168.0.0/16`).
- Do not overlap with existing VPC CIDRs in this account/region.
- Do not overlap with networks reachable through TGW, peering, VPN, or Direct Connect.
- Keep it consistent with your subnet sizing plan (this module derives subnets from the VPC CIDR).

Address space sizing:

- A `/16` has 65,536 total IPs.
- In AWS, each subnet reserves 5 IPs, but VPC-level CIDR capacity is still that size envelope.
- Two `/16`s (`10.40.0.0/16` + `10.41.0.0/16`) give you about 131,072 total addresses in one VPC.
- AWS does not allow a VPC primary CIDR of `/15`, so use a primary `/16` plus one additional `/16` if you need that headroom.

Recommendation:

- Start with a non-overlapping `/16` in `SHARED_VPC_CIDR`.
- If you want extra headroom, add another non-overlapping `/16` in `SHARED_VPC_ADDITIONAL_CIDRS`.

Why you might need that much:

- Future growth in runners, services, and subnet count.
- Room to expand without adding secondary CIDRs later.
- Cleaner long-term network planning in shared environments.

Benefits of using two `/16`s from day one:

- More free address space from day one (about 131,072 total).
- Fewer future rework events (subnet pressure, CIDR expansion planning).
- Aligns with AWS VPC CIDR constraints (`/16` to `/28` per CIDR association).

Check in AWS Console:

1. Open **AWS Console** in the target account and region.
2. Go to **VPC** → **Your VPCs**.
3. Review the **CIDRs** column for existing VPC ranges.
4. If Transit Gateway is used, also check **VPC** → **Transit Gateway Attachments** (and any peering/VPN/direct connect routes your team uses) to avoid overlap with connected networks.

Check in CloudShell (same account/region):

```bash
# Set your region once
AWS_REGION="us-east-1"

# List VPC CIDRs in this region
aws ec2 describe-vpcs \
  --region "$AWS_REGION" \
  --query "Vpcs[*].[VpcId,CidrBlock,Tags[?Key=='Name']|[0].Value]" \
  --output table

# Optional: list TGW VPC attachments in this region (to understand connected VPCs)
aws ec2 describe-transit-gateway-vpc-attachments \
  --region "$AWS_REGION" \
  --query "TransitGatewayVpcAttachments[*].[TransitGatewayAttachmentId,TransitGatewayId,VpcId,State]" \
  --output table
```

Optional IPAM policy check:

```bash
aws ec2 describe-ipam-pools --region "$AWS_REGION" --output table
```

If this prints only the table header (for example `DescribeIpamPools` with no rows), it means no IPAM pools are visible in this account/region or your current role does not have permission to read them.

How to know which CIDR to pick:

Choose a block that is:

- In private RFC1918 space:
  - `10.0.0.0/8`
  - `172.16.0.0/12`
  - `192.168.0.0/16`
- Not present in your current VPC CIDR list.
- Not overlapping TGW-connected networks.
- Allowed by your org IP policy or IPAM (if used).

What is RFC1918?

RFC1918 private IPv4 ranges:

- `10.0.0.0/8` (10.0.0.0 - 10.255.255.255)
- `172.16.0.0/12` (172.16.0.0 - 172.31.255.255)
- `192.168.0.0/16` (192.168.0.0 - 192.168.255.255)

In AWS VPCs, use CIDRs from one of these private ranges.

Did we already run a TGW check?

Yes. `describe-transit-gateway-vpc-attachments` is the TGW connectivity check. It tells you which VPCs are attached; then compare their CIDRs from `describe-vpcs` to ensure no overlap.

How to check org policy or IPAM in CloudShell:

```bash
aws ec2 describe-ipams --region "$AWS_REGION" --output table
aws ec2 describe-ipam-pools --region "$AWS_REGION" --output table
```

If these return nothing (or access denied), your org may not use IPAM in that account/region, or your role cannot read it. If `describe-ipam-pools` prints only the table header (for example `DescribeIpamPools` with no rows), treat that as no pools visible in this account/region for your current permissions. In that case, confirm allowed CIDR ranges with your network/platform team.

Good vs bad examples:

- Good: set `SHARED_VPC_CIDR=10.42.0.0/16` and `SHARED_VPC_ADDITIONAL_CIDRS=["10.43.0.0/16"]` when both are non-overlapping.
- Bad: choosing `10.40.0.0/16` again when a VPC already uses that CIDR, or adding a secondary CIDR that overlaps existing/connected networks.
- Policy check: confirm both `/16` CIDRs are allowed by your org network standards or IPAM pool constraints before deploy.

### Detailed CIDR selection walkthrough

#### How to pick `SHARED_VPC_CIDR`

#### What to do first

In CloudShell, set your target region:

```bash
AWS_REGION="us-east-1"
```

List existing VPC CIDRs in this account/region:

```bash
aws ec2 describe-vpcs \
  --region "$AWS_REGION" \
  --query "Vpcs[*].[VpcId,CidrBlock,Tags[?Key=='Name']|[0].Value]" \
  --output table
```

If using Transit Gateway, list attached VPCs (connected networks):

```bash
aws ec2 describe-transit-gateway-vpc-attachments \
  --region "$AWS_REGION" \
  --query "TransitGatewayVpcAttachments[*].[TransitGatewayAttachmentId,TransitGatewayId,VpcId,State]" \
  --output table
```

Optional quick CIDR-only view:

```bash
aws ec2 describe-vpcs \
  --region "$AWS_REGION" \
  --query "Vpcs[*].CidrBlock" \
  --output text
```

Pick a non-overlapping primary `/16` for `SHARED_VPC_CIDR` (for example `10.60.0.0/16`).  
If you need more headroom, add a second non-overlapping `/16` in `SHARED_VPC_ADDITIONAL_CIDRS` (for example `["10.61.0.0/16"]`).

#### How to pick AZs (`SHARED_NETWORKING_AZS`)

Pick at least 2 AZs in the chosen region for resiliency.

In CloudShell:

First, set the AWS region:

```bash
AWS_REGION="us-east-1"
```

Then, list AZ names:

```bash
aws ec2 describe-availability-zones \
  --region "$AWS_REGION" \
  --query "AvailabilityZones[?State=='available'].ZoneName" \
  --output text
```

Then pick 2 of those AZs and set `SHARED_NETWORKING_AZS` as JSON, for example:

```json
["us-east-1a","us-east-1d"]
```

#### How to know which CIDR to pick

Choose a block that is:

- In private RFC1918 space:
  - `10.0.0.0/8`
  - `172.16.0.0/12`
  - `192.168.0.0/16`
- Not present in your current VPC CIDR list.
- Not overlapping TGW-connected networks.
- Allowed by your org IP policy/IPAM (if used).

Why those ranges (they are not random):

- These are the globally reserved private IPv4 ranges defined by RFC1918.
- They are intended for internal networks and are not publicly routable on the internet.
- AWS VPC private addressing is built around these private ranges.

#### What is RFC1918?

RFC1918 private IPv4 ranges:

- `10.0.0.0/8` (10.0.0.0 - 10.255.255.255)
- `172.16.0.0/12` (172.16.0.0 - 172.31.255.255)
- `192.168.0.0/16` (192.168.0.0 - 192.168.255.255)

In AWS VPCs, use CIDRs from one of these private ranges.

#### Did we already run a TGW check?

Yes. `describe-transit-gateway-vpc-attachments` is the TGW connectivity check. It tells you which VPCs are attached; then compare their CIDRs from `describe-vpcs` to ensure no overlap.

#### How to check org policy / IPAM in CloudShell

If your org uses AWS VPC IPAM, check pools/allocations:

```bash
aws ec2 describe-ipams --region "$AWS_REGION" --output table
aws ec2 describe-ipam-pools --region "$AWS_REGION" --output table
```

If these return nothing (or access denied), your org may not use IPAM in that account/region, or your role cannot read it. In that case, confirm allowed CIDR ranges with your network/platform team.

If `describe-ipam-pools` output only shows the header (for example `DescribeIpamPools`) with no rows, it means no pools are visible in this account/region or your role lacks read permission.

**To find the correct AMI for your region:**

The AMI ID is different for each AWS region and changes when AWS releases updates. You need the latest ECS-optimized AMI for your specific region.

**Option 1: Using AWS CLI (Recommended)**
```bash
# Replace YOUR_REGION with your region (e.g., us-east-1)
aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=amzn2-ami-ecs-hvm-*" \
  --query 'Images[*].[ImageId,CreationDate]' \
  --output table \
  --region YOUR_REGION | sort -k2 -r | head -1
```
This will show the most recent AMI ID for your region.

**Option 2: Using AWS Console**
1. Go to AWS Console → EC2 → AMIs
2. Search for `amzn2-ami-ecs-hvm`
3. Filter by your region
4. Sort by "Creation date" (newest first)
5. Copy the AMI ID (starts with `ami-`)

**Option 3: AWS Documentation**
- Go to: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html
- Find the table for your region and instance type
- Copy the AMI ID

**If you're unsure:** Ask your AWS administrator or DevOps team - they may have a standard AMI they use or can help you find the correct one for your region.

**What this does:** The GitHub Actions workflow uses these secrets and variables to configure Terraform automatically when you deploy. The workflow reads these values and passes them to Terraform as environment variables (prefixed with `TF_VAR_`), which Terraform then uses to create and configure your AWS resources.

### Quick Validation: Run the Workflows in Your Fork

Once you fork the repository and set your GitHub **Secrets** and **Variables**, you can validate the setup by running the workflows:

1. **Build & Push Docker Image** (`.github/workflows/docker-build.yml`)
   - Choose your branch; set image tag to `latest`.
2. **Multi-Org github runner Deployment** (`.github/workflows/deployment.yml`)
   - Choose your branch; choose **plan** (recommended first validation). When `SHARED_CREATE_NETWORKING` is true, it will create the VPC, subnets, and TGW in the same run.
3. **Deploy networking only** (`.github/workflows/deploy-networking.yml`) – Optional. Use a separate state file to create or change only networking; see [.github/workflows/deploy-networking-README.md](.github/workflows/deploy-networking-README.md) (requires `TF_NETWORKING_STATE_KEY` and networking Variables).

If the main deployment and docker-build runs turn green, your configuration is likely correct. If any run turns red, start with **Troubleshooting workflow failures (red runs)** below.

### Step 9: Deploy Everything

Deployment is done via the GitHub Actions workflow. This automatically uses your configured secrets and variables from Step 8.

**1. Go to the Actions Tab**

In your GitHub repository, click on the **Actions** tab.

**2. Run the Deployment Workflow**

1. Click on **Multi-Org github runner Deployment** in the workflow list
2. Click **Run workflow** (dropdown button on the right)
3. Pick the branch you want to run it from (use your default branch unless you are testing changes on a branch)
3. Select the action you want:
   - **plan** - Preview what will be created (recommended first time)
   - **deploy** - Actually create everything in AWS
   - **destroy** - Remove everything (use with caution!)
4. Click the green **Run workflow** button

**(Optional) Screenshot placeholder:** Add a screenshot of the **Run workflow** dialog for this workflow here:
`docs/screenshots/deployment-run-workflow.png`

**3. Monitor the Deployment**

- The workflow will show progress in real-time
- For **plan**: Review the output to see what will be created
- For **deploy**: This takes 5-10 minutes to create all resources
- Watch for any errors in the workflow logs

**Important (first-time validation): choose `plan` only**
- At this step, only run **plan**. Do not run **deploy** or **destroy** unless you intentionally want to change AWS resources.
- **plan** shows what would change and does not create resources.
- **deploy** / **destroy** perform Terraform apply operations, which *do* modify AWS and can cost money.

**What's happening behind the scenes:**
- The workflow uses your GitHub secrets/variables to configure Terraform
- Creating an ECS cluster (a group to manage your runners)
- Creating EC2 instances (the actual computers) or Fargate tasks
- Setting up networking and security
- Creating storage (EFS) for runner settings
- Starting your first runner
- If **create networking** is enabled (`SHARED_CREATE_NETWORKING` = `true`), it creates the VPC, subnets, and Transit Gateway first, then deploys into them
- You can also run the **Deploy networking only** workflow (separate state file) to create or change just the networking without touching the main deployment; see [.github/workflows/deploy-networking-README.md](.github/workflows/deploy-networking-README.md)
- When create networking is used, Terraform outputs include `networking_vpc_id`, `networking_vpc_cidrs`, `networking_subnet_ids`, and `networking_transit_gateway_id` (visible after apply or via `terraform output`).

**Important:**
- This step costs money (you're creating AWS resources)
- Make sure all secrets and variables are set correctly before deploying
- If something goes wrong, you can run the workflow with **destroy** action to clean up

### Troubleshooting workflow failures (red runs)

If either workflow run turns red, start here:

**Common causes:**
- Missing or misspelled GitHub **Secrets/Variables** (Step 8)
- AWS OIDC role/permissions issues (`SHARED_AWS_ROLE_NAME`, trust policy, missing permissions)
- Terraform backend issues (`TF_BACKEND_BUCKET` missing/wrong region/permissions)
- ECR access issues (image pull/push `401 Unauthorized`, wrong account/region, missing repo permissions)
- Network/VPC issues (wrong `SHARED_VPC_ID`, `SHARED_SUBNETS`, or security groups)

**Fast debug tips:**
- Open the failed job and read the *first* error in the logs (later errors are often cascading failures).
- For ECR errors, confirm the image/account/region you’re using matches the AWS account the workflow assumes.
- For Terraform errors, search the log for `Error:` and the resource name; fix the upstream config and re-run **plan** first.

**Account/region preflight (before deeper troubleshooting):**
- In organizations that use AWS Access Portal, first confirm you opened the intended account, then confirm the AWS Console region selector matches `SHARED_AWS_REGION`.
- In CloudShell, verify current account and region context:
  ```bash
  aws sts get-caller-identity --query Account --output text
  aws configure get region
  ```
- If you see an error that includes **"explicit deny in a service control policy"**, this is an AWS Organizations SCP restriction (or wrong account/region context), not a Terraform code bug.

### Step 10: Check That It Works

After deployment finishes, verify everything is working:

**1. Check if the Runner is Running**

Go to your GitHub organization/repository:
- Click **Settings** → **Actions** → **Runners**
- You should see a runner with the name you set in `runner_name_prefix`
- It should show as "Idle" (green) - this means it's ready to work!

**2. Check the Logs (if the runner isn't showing up)**

If the runner doesn't appear in GitHub, check the logs:

```bash
# First, find your cluster name (from your config file)
CLUSTER_NAME="my-github-runners"  # Replace with your cluster_name

# Find the service name (usually "default" or what you named it)
SERVICE_NAME="default"  # Replace with your service name if different

# Check the service status
aws ecs describe-services \
  --cluster $CLUSTER_NAME \
  --services $SERVICE_NAME \
  --region YOUR_AWS_REGION
```

**3. View Detailed Logs**

```bash
# The log group name is usually: /ecs/github-runner-<service-name>
aws logs tail /ecs/github-runner-default --follow --region YOUR_AWS_REGION
```

**What to look for in logs:**
- "Runner successfully started" - Good!
- "Connected to GitHub" - Good!
- Any error messages - These tell you what's wrong

**4. Test It Works**

Create a simple GitHub Actions workflow to test:

1. Go to your repository
2. Create `.github/workflows/test-runner.yml`:
   ```yaml
   name: Test Runner
   on: [push]
   jobs:
     test:
       runs-on: [self-hosted]  # Use one of your runner_labels
       steps:
         - name: Hello World
           run: echo "Runner is working!"
   ```
3. Commit and push
4. Go to **Actions** tab - you should see your workflow running on your runner!

**If something's wrong:** See the [Common Problems](#common-problems-and-solutions) section below.

## Using Your Runners

Now that your runners are set up, you can use them in your GitHub Actions workflows!

### Basic Usage

In any GitHub Actions workflow file (`.github/workflows/*.yml`), use the `runs-on` keyword with your runner labels:

```yaml
name: My Workflow
on: [push]

jobs:
  build:
    runs-on: [self-hosted, team-a]  # These match your runner_labels from Step 6
    steps:
      - uses: actions/checkout@v4
      - name: Run a command
        run: echo "This is running on MY runner!"
      - name: Build with Docker
        run: docker build -t myapp .
```

**Important:** The labels in `runs-on` must match the labels you set in the `SHARED_RUNNER_LABELS` variable in Step 8!

### What Your Runner Can Do

- **Run any commands** - Just like GitHub's runners, but on your own computers
- **Use Docker** - If you enabled Docker-in-Docker (DinD), you can build Docker images
- **Access AWS** - Your runner automatically has AWS credentials (via the ECS task role)
  - You can use `aws` CLI commands without setting up credentials
  - You can use AWS SDKs in your code

### Example: Using AWS in Your Workflow

```yaml
jobs:
  deploy:
    runs-on: [self-hosted]
    steps:
      - name: List S3 buckets
        run: aws s3 ls  # Works automatically - no credentials needed!
```

## What Each Setting Does

This section provides reference information for all configuration options. For step-by-step setup instructions, see [Step 8: Set Up GitHub Secrets and Variables](#step-8-set-up-github-secrets-and-variables).

### Settings in `env/multi-org.tfvars` (Infrastructure Configuration)

| Setting | What It Does | Default Value |
|---------|--------------|---------------|
| `cluster_name` | Name for your ECS cluster | `nexus-repo` |
| `create_cluster` | Create a new cluster (false = use existing) | `false` |
| `launch_type` | Type of runner: `"EC2"` or `"FARGATE"` | `"EC2"` |
| `instance_type` | Size of EC2 computer | `"t3.medium"` |
| `asg_min_size` | Minimum number of computers | `0` |
| `asg_max_size` | Maximum number of computers | `5` |
| `asg_desired_capacity` | How many computers to start with | `1` |
| `enable_docker_prune_cron` | Auto-cleanup old Docker files | `true` |
| `docker_prune_cron_schedule` | When to run cleanup (cron format) | `"0 * * * *"` (hourly) |
| `docker_prune_until` | Remove files older than this | `"3h"` |
| `docker_volume_size` | Size of disk in GB | `100` |

### Running Multiple Organizations/Repositories

The current GitHub Actions workflow (`.github/workflows/deployment.yml`) is configured for a single runner service. The infrastructure supports multiple services, but you would need to modify the workflow's `TF_VAR_runner_services` environment variable to include multiple services in JSON format.

**To add more services, you would need to:**

1. Edit `.github/workflows/deployment.yml`
2. Modify the `TF_VAR_runner_services` environment variable (around line 77) to build a JSON object with multiple services
3. Add additional secrets/variables for each additional service

**For each service, you can configure:**
- `desired_count` - How many runners for this service
- `runner_image` - Different Docker image
- `runner_name_prefix` - Different name prefix
- `runner_labels` - Different labels
- `github_org` - GitHub organization
- `runner_token_ssm_parameter_name` - SSM parameter for token

## Common Problems and Solutions

### Problem: Runner Doesn't Appear in GitHub

**What you see:** The deployment workflow completed successfully, but the runner doesn't show up in GitHub.

**How to fix:**

1. **Check if the runner is actually running:**
   ```bash
   aws ecs list-services --cluster YOUR_CLUSTER_NAME --region YOUR_REGION
   ```

2. **Check the logs for errors:**
   ```bash
   aws logs tail /ecs/github-runner-default --follow --region YOUR_REGION
   ```
   Look for error messages - they'll tell you what's wrong.

3. **Common causes:**
   - Token expired (see "Token Expired" below)
   - Wrong GitHub organization name in config
   - Network issues (runner can't reach GitHub)

### Problem: Token Expired

**What you see:** Logs show "token expired" or "authentication failed"

**Why this happens:** GitHub runner tokens expire after 1 hour. If you took too long setting things up, the token is no longer valid.

**How to fix:**

1. **Get a new token** (go back to [Step 4](#step-4-get-a-github-runner-token))
2. **Update the token in AWS:**
   ```bash
   aws ssm put-parameter \
     --name "github-runner/token" \
     --value "YOUR_NEW_TOKEN" \
     --type "SecureString" \
     --region YOUR_REGION \
     --overwrite
   ```
3. **Restart the runner:**
   ```bash
   aws ecs update-service \
     --cluster YOUR_CLUSTER_NAME \
     --service YOUR_SERVICE_NAME \
     --force-new-deployment \
     --region YOUR_REGION
   ```

### Problem: Custom Labels Not Showing

**What you see:** In GitHub, you only see default labels like `self-hosted`, `Linux`, `X64`, but not your custom labels.

**Why this happens:** The runner was registered before you set the labels, and it's using old settings stored on the disk.

**How to fix:**

Force the runner to re-register with new labels:

```bash
aws ecs update-service \
  --cluster YOUR_CLUSTER_NAME \
  --service YOUR_SERVICE_NAME \
  --force-new-deployment \
  --region YOUR_REGION
```

This restarts the runner and it will pick up the new labels.

### Problem: Out of Disk Space

**What you see:** Errors like `no space left on device` or tasks failing to start.

**Why this happens:** Docker creates a lot of temporary files (containers, images, volumes) that fill up the disk over time.

**How to fix:**

**Option 1 (Quick fix):** Restart the EC2 instances to get fresh disks:
- Go to AWS Console → EC2 → Auto Scaling Groups
- Find your ASG → Instance Management → Terminate instances
- New instances will start automatically

**Option 2 (Long-term fix):** The automatic cleanup is already enabled by default in `env/multi-org.tfvars`:

```hcl
enable_docker_prune_cron   = true
docker_prune_cron_schedule = "0 * * * *"  # Runs every hour
docker_prune_until         = "3h"         # Removes files older than 3 hours
```

Then run the deployment workflow again with the **deploy** action. This will automatically clean up old Docker files.

### Problem: EFS Mount Fails

**What you see:** Tasks fail to start with errors about EFS or mount failures.

**Why this happens:** Your VPC doesn't have DNS enabled, so the runner can't find the EFS storage.

**How to fix:**

Enable DNS in your VPC:

```bash
aws ec2 modify-vpc-attribute --vpc-id YOUR_VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id YOUR_VPC_ID --enable-dns-support
```

Then restart your services:

```bash
aws ecs update-service \
  --cluster YOUR_CLUSTER_NAME \
  --service YOUR_SERVICE_NAME \
  --force-new-deployment \
  --region YOUR_REGION
```

### Problem: Can't Find the Right AMI

**What you see:** Terraform fails with "AMI not found" or similar error.

**Why this happens:** The AMI ID in your config is for a different region, or it's outdated.

**How to find the right AMI:**

1. **Use AWS Console:**
   - Go to EC2 → AMIs
   - Search for "amzn2-ami-ecs-hvm"
   - Filter by your region
   - Copy the AMI ID

2. **Or use AWS CLI:**
   ```bash
   aws ec2 describe-images \
     --owners amazon \
     --filters "Name=name,Values=amzn2-ami-ecs-hvm-*" \
     --query 'Images[*].[ImageId,CreationDate]' \
     --output table \
     --region YOUR_REGION | sort -k2 -r | head -1
   ```

Then update the `SHARED_INSTANCE_AMI` variable in GitHub repository settings (Settings → Secrets and variables → Actions → Variables) with the new AMI ID and run the deployment workflow again with the **deploy** action.

### Still Having Problems?

1. **Check the logs** - They usually tell you exactly what's wrong
2. **Check AWS Console** - Look at ECS services, CloudWatch logs, and EC2 instances
3. **Verify your config** - Make sure all IDs and names are correct
4. **Ask for help** - Share the error messages and logs with your team

## Removing Everything

If you want to delete everything you created (to stop paying for it or start over):

**⚠️ WARNING: This permanently deletes everything! Make sure you really want to do this.**

**Using GitHub Actions Workflow (Recommended):**

1. Go to your GitHub repository → **Actions** tab
2. Click on **Multi-Org github runner Deployment**
3. Click **Run workflow**
4. Select **destroy** from the action dropdown
5. Click the green **Run workflow** button
6. Monitor the workflow to confirm everything is deleted

**What this does:**
- Deletes the ECS cluster
- Deletes all EC2 instances
- Deletes the EFS storage (all runner settings will be lost!)
- Deletes all runner services
- Deletes security groups and networking resources

**What this does NOT delete:**
- Your Docker image in ECR (you'll need to delete that separately if you want)
- The SSM parameter with your token (you'll need to delete that separately)
- Your VPC and subnets (those stay because they might be used by other things)

**After running this:**
- You'll stop paying for these AWS resources
- You'll need to set everything up again from scratch if you want runners later
- Your runners will disappear from GitHub

**To delete the Docker image and token too:**

```bash
# Delete the ECR repository (and image)
aws ecr delete-repository \
  --repository-name github-runner \
  --force \
  --region YOUR_REGION

# Delete the SSM parameter
aws ssm delete-parameter \
  --name "github-runner/token" \
  --region YOUR_REGION
```

