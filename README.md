# How to Set Up GitHub Actions Runners on AWS

This guide will help you deploy your own GitHub Actions runners on Amazon Web Services (AWS). Think of this as creating your own computers in the cloud that can run your GitHub Actions workflows instead of using GitHub's shared runners.

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

## Table of Contents

- [What You Need Before Starting](#what-you-need-before-starting)
- [Step-by-Step Setup Guide](#step-by-step-setup-guide)
  - [Step 1: Get Your AWS Account Information](#step-1-get-your-aws-account-information)
  - [Step 2: Understand the Deployment Workflow](#step-2-understand-the-deployment-workflow)
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

## What You Need Before Starting

Before you begin, make sure you have:

1. **An AWS Account** - You'll need access to create resources
2. **AWS CLI Installed** - A tool to talk to AWS from your computer
   - Download: https://aws.amazon.com/cli/
   - After installing, run: `aws configure` to set up your credentials
3. **Terraform Installed** - A tool that creates AWS resources for you
   - Download: https://www.terraform.io/downloads
   - Version 1.0 or newer
4. **Docker Installed** - To build the runner image
   - Download: https://www.docker.com/get-started
5. **GitHub Access** - Admin access to the GitHub organization or repository where you want to add runners
6. **A VPC in AWS** - A virtual network (we'll help you check this)

## Step-by-Step Setup Guide

Follow these steps in order. Don't skip ahead - each step depends on the previous one!

### Step 0: Fork the Repository (and When to Use a Branch)

**Goal:** You should be able to **fork this repository**, fill in your own GitHub **Secrets** and **Variables**, and run the included GitHub Actions workflows to validate everything works.

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

1. **Your AWS Account ID** - A 12-digit number
   - Find it: Log into AWS Console → Click your username (top right) → The account ID is shown there
   - Or run: `aws sts get-caller-identity --query Account --output text`

2. **Your AWS Region** - Where you want to create everything (e.g., `us-east-1`, `us-west-2`, `eu-west-1`)
   - This is usually shown in the top-right of the AWS Console
   - Common regions: `us-east-1` (N. Virginia), `us-west-2` (Oregon), `eu-west-1` (Ireland)

**Write these down** - you'll need them in later steps!

### Step 2: Understand the Deployment Workflow

Before gathering all the information you need, it's helpful to understand what the deployment workflow requires. This way, you'll know **why** you're collecting each piece of information in the following steps.

The deployment is handled by a GitHub Actions workflow located at `.github/workflows/deployment.yml`. This workflow uses GitHub repository **secrets** and **variables** to configure Terraform automatically.

**What the workflow needs:**

The workflow requires you to set up GitHub repository secrets and variables. Here's what you'll need to collect, with detailed explanations:

**GitHub Secrets (sensitive information):**

| Secret Name | Example Value | Why You Need This | Where to Get This |
|------------|---------------|-------------------|-------------------|
| `SHARED_AWS_ACCOUNT_ID` | `123456789012` | Used to construct ARNs and assume IAM roles. The workflow needs this to authenticate with AWS using OIDC. | See Step 1 for instructions. |
| `SHARED_VPC_ID` | `vpc-0123456789abcdef0` | The runners need to be deployed into a specific VPC (Virtual Private Cloud) for network isolation and security. This tells Terraform which VPC to use. | See Step 3 for instructions. If you don't have access, ask your AWS administrator or network team. |
| `SHARED_SUBNETS` | `subnet-0123456789abcdef0,subnet-0fedcba9876543210` | Subnets are specific network segments within your VPC. You need at least 2 subnets (preferably in different Availability Zones) for high availability. The runners will be deployed across these subnets. | See Step 3 for instructions. If unsure which subnets to use, ask your AWS administrator - they should be private subnets (not public internet-facing ones). |
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
| `SHARED_RUNNER_IMAGE` | `123456789012.dkr.ecr.us-east-1.amazonaws.com/github-runner:latest` | This is the Docker image that contains the GitHub Actions runner software. ECS will pull this image and run it as containers on your EC2 instances. | See Step 6 for instructions. The format is: `ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/REPOSITORY_NAME:TAG` |
| `SHARED_DESIRED_COUNT` | `1`, `2`, `5` | This controls how many runner containers will be running simultaneously. More runners = more workflows can run in parallel, but also higher AWS costs. Start with 1 and increase if you need more parallel capacity. | Consider your typical workflow load. If you have many concurrent workflows, you may need 2-5 runners. If workflows run sequentially, 1 is usually sufficient. You can always change this later and redeploy. |
| `SHARED_RUNNER_NAME_PREFIX` | `ecs-github-runner`, `aws-runner-prod`, `team-a-runner` | This prefix appears in the GitHub runner list to help identify your runners. GitHub will append a unique identifier, so you'll see names like `ecs-github-runner-abc123`. | Pick something descriptive that helps you identify these runners in GitHub's UI. Include environment or team info if you have multiple sets of runners (e.g., `prod-runner`, `dev-runner`). |
| `SHARED_RUNNER_LABELS` | `self-hosted,team-a,ecs,ec2`, `self-hosted,linux,x64,production` | Labels allow you to target specific runners in your GitHub Actions workflows using `runs-on: [label1, label2]`. You can use labels to route workflows to specific runner types, teams, or environments. | Include `self-hosted` (required by GitHub), plus descriptive labels like team names, environment (prod/dev), or capabilities (docker, large, etc.). Common labels: `self-hosted`, `linux`, `x64`, plus your custom labels. Think about how you want to organize workflow routing. |
| `SHARED_INSTANCE_AMI` | `ami-0123456789abcdef0` (this will be different for each region) | This is the Amazon Machine Image (operating system) that will run on your EC2 instances. The ECS-optimized AMI is pre-configured with Docker and the ECS agent needed to run containers. | See Step 8 for instructions on finding the correct AMI. The AMI ID is different for each region, so make sure you get the one for your specific region. If you're unsure, ask your AWS administrator or use the AWS documentation link provided in Step 8. |

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

**Don't have a VPC?** Ask your AWS administrator to create one, or create a simple one in the AWS Console (VPC → Create VPC).

**Why you need this:** The deployment workflow needs your VPC ID, subnet IDs, and security group IDs for the `SHARED_VPC_ID`, `SHARED_SUBNETS`, and `SHARED_SECURITY_GROUP_IDS` secrets you'll set up in Step 8.

### Step 4: Get a GitHub Runner Token

This token lets your runner connect to GitHub. Here's how to get it:

1. Go to your GitHub organization or repository
2. Click **Settings** (at the top of the page)
3. Click **Actions** (in the left sidebar)
4. Click **Runners** (in the left sidebar)
5. Click **New self-hosted runner** (green button)
6. Copy the token that appears (it's a long string of letters and numbers)

> ⚠️ **IMPORTANT**: This token expires in 1 hour! If you take longer than an hour to finish setup, you'll need to get a new token.

**Write this token down** - you'll use it in the next step!

**Why you need this:** The deployment workflow needs a runner token stored in AWS SSM Parameter Store. The parameter name you choose will be used for the `SHARED_RUNNER_TOKEN_SSM_PARAMETER_NAME` secret in Step 8.

### Step 5: Save the Token Securely in AWS

We'll store your GitHub token in AWS Systems Manager Parameter Store (think of it as a secure password vault).

Run this command (replace the parts in `<brackets>`):

```bash
aws ssm put-parameter \
  --name "github-runner/token" \
  --value "YOUR_TOKEN_FROM_STEP_3" \
  --type "SecureString" \
  --region YOUR_AWS_REGION \
  --overwrite
```

**What to replace:**
- `YOUR_TOKEN_FROM_STEP_3` - The token you copied in Step 3
- `YOUR_AWS_REGION` - The region you wrote down in Step 1 (e.g., `us-east-1`)
- `"github-runner/token"` - You can change this name if you want, but remember what you called it!

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

**(Optional) Screenshot placeholder:** Add a screenshot of the **Run workflow** dialog for this workflow here:
`docs/screenshots/docker-build-run-workflow.png`

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
| `SHARED_VPC_ID` | Your VPC ID | `vpc-0123456789abcdef0` | Specifies which VPC network the runners will be deployed into for network isolation | **Step 3** - Found in AWS Console (VPC → Your VPCs). If you don't have this, ask your AWS administrator or network team |
| `SHARED_SUBNETS` | Comma-separated subnet IDs (no spaces) | `subnet-0123456789abcdef0,subnet-0fedcba9876543210` | Specifies which subnets (network segments) the runners will use. Need at least 2 for high availability | **Step 3** - Found in AWS Console (VPC → Subnets). Ask your AWS administrator which private subnets to use if unsure |
| `SHARED_SECURITY_GROUP_IDS` | Comma-separated security group IDs (no spaces) | `sg-0123456789abcdef0` | Controls network traffic rules (firewall) for the runners. Must allow outbound HTTPS to GitHub and AWS APIs | **Step 3** - Found in AWS Console (VPC → Security Groups). If you need to create new ones, ask your security team about required rules |
| `SHARED_RUNNER_SERVICE_NAME` | A name for your runner service | `default` or `production-runners` | Identifies this ECS service. Used for organization if you have multiple runner services | **You choose this** - Pick a descriptive name. Common: `default`, `prod-runners`, `dev-runners`, `team-a-runners` |
| `SHARED_GITHUB_ORG` | Your GitHub organization name | `my-company` or `acme-corp` | The GitHub organization where runners will register and appear. Must match your org's URL name | **Your GitHub org** - Found in your GitHub org URL: `https://github.com/YOUR_ORG_NAME`. If deploying for a repo, check with your GitHub admin |
| `SHARED_RUNNER_TOKEN_SSM_PARAMETER_NAME` | The SSM parameter path/name | `github-runner/token` or `/github/runners/token` | The path in AWS Parameter Store where the GitHub runner token is stored. Runners retrieve this to authenticate | **Step 5** - The parameter name you used when storing the token (e.g., `github-runner/token`) |
| `SHARED_AWS_ROLE_NAME` | IAM role name for GitHub Actions | `GitHubActionsTerraformRole` or `github-actions-deploy-role` | Allows GitHub Actions workflow to authenticate with AWS via OIDC (no long-lived credentials needed) | **Ask your AWS admin** - This role must exist and have permissions to create ECS, EC2, VPC, IAM resources. If it doesn't exist, ask your DevOps/Infrastructure team to create it |
| `TF_BACKEND_BUCKET` | S3 bucket name for Terraform state | `my-company-terraform-state` or `github-runner-terraform-state` | Stores Terraform's state file so the workflow knows what resources already exist. Must have versioning enabled | **Ask your DevOps team** - Check if your organization has a standard Terraform state bucket. If not, create one or ask your AWS administrator. Should be in the same region as your deployment |

**2. Set up GitHub Repository Variables**

Go to **Settings** → **Secrets and variables** → **Actions** → **Variables** tab, and add these variables:

| Variable Name | What to Enter | Example Value | Why You Need This | Where You Got This |
|--------------|---------------|---------------|-------------------|-------------------|
| `SHARED_AWS_REGION` | Your AWS region code | `us-east-1`, `us-west-2`, `eu-west-1` | All AWS resources will be created in this region. Choose based on proximity to users or compliance requirements | **Step 1** - Found in AWS Console top-right, or ask your AWS administrator about your org's preferred region |
| `SHARED_RUNNER_IMAGE` | Full ECR image URI | `123456789012.dkr.ecr.us-east-1.amazonaws.com/github-runner:latest` | The Docker image containing the GitHub Actions runner software. ECS pulls this to run your runners | **Step 6** - The full image path after building and pushing to ECR. Format: `ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/REPOSITORY:TAG` |
| `SHARED_DESIRED_COUNT` | Number of runners (as a number) | `1`, `2`, or `5` | How many runner containers to run simultaneously. More = more parallel workflows but higher cost | **You choose this** - Start with `1` for testing. Increase to 2-5 if you need more parallel capacity. Can change later |
| `SHARED_RUNNER_NAME_PREFIX` | Prefix for runner names | `ecs-github-runner`, `aws-runner-prod`, `team-a-runner` | Appears in GitHub's runner list to identify your runners. GitHub adds a unique suffix | **You choose this** - Pick something descriptive. Examples: `ecs-github-runner`, `prod-runner`, `team-a-runner`. Include environment/team info if you have multiple sets |
| `SHARED_RUNNER_LABELS` | Comma-separated labels (no spaces after commas) | `self-hosted,team-a,ecs,ec2` or `self-hosted,linux,x64,production` | Used in `runs-on:` in workflows to target specific runners. Allows routing workflows to specific runner types | **You choose this** - Must include `self-hosted`. Add descriptive labels like team names, environment, or capabilities. Examples: `self-hosted,linux,x64,prod` or `self-hosted,team-a,docker,large` |
| `SHARED_INSTANCE_AMI` | ECS-optimized AMI ID for your region | `ami-0123456789abcdef0` (varies by region) | The operating system image for EC2 instances. ECS-optimized AMI has Docker and ECS agent pre-installed | **See instructions below** - AMI ID is different for each region. Use the latest ECS-optimized AMI for your specific region |

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

Once you fork the repository and set your GitHub **Secrets** and **Variables**, you can validate the setup by running the two workflows:

1. **Build & Push Docker Image** (`.github/workflows/docker-build.yml`)
   - Choose your branch
   - Set image tag to `latest`
2. **Multi-Org github runner Deployment** (`.github/workflows/deployment.yml`)
   - Choose your branch
   - Choose **plan** (recommended first validation)

If both runs turn green, your configuration is likely correct. If either run turns red, start with **Troubleshooting workflow failures (red runs)** below.

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

