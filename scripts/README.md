# Scripts

## Prerequisites: IAM roles for GitHub Actions

The deployment workflow (`.github/workflows/deployment.yml`) uses GitHub OIDC to assume an IAM role in AWS. Before the workflow can run Terraform, you must create that role and related roles in your AWS account.

### What the script creates

The script creates three IAM roles. The name of each role is set by you via the environment variable in the first column (no fixed names in the script).

| Role (env var sets the name) | Purpose |
|------------------------------|--------|
| `GITHUB_ACTIONS_ROLE` | Role that GitHub Actions assumes via OIDC. Can assume the other two roles. Has AdministratorAccess. |
| `STATE_ROLE_NAME` | Access to the Terraform state S3 bucket. Trust: the GitHub Actions role from the same AWS Organization. |
| `TERRAFORM_EXEC_ROLE` | Role used to run Terraform (plan/apply). Trust: the GitHub Actions role in this account only. Has AdministratorAccess. |

The script also creates the GitHub OIDC identity provider in IAM (`token.actions.githubusercontent.com`) if it does not exist.

### No hardcoded values

The script reads all configuration from **environment variables**. There are no account IDs, bucket names, GitHub org/repo names, or role names in the script.

### How to read variable names in this README

When you see names like `TF_BACKEND_BUCKET`, `AWS_ACCOUNT_ID`, or `GITHUB_ACTIONS_ROLE` in this document:

- These are **variable keys** (labels), not literal values you must name resources after.
- You provide the real value in your shell session, for example:
  - `TF_BACKEND_BUCKET=your-actual-bucket-name`
  - `GITHUB_ACTIONS_ROLE=github-actions-role`
- Later, some of those values are copied into GitHub Secrets/Variables with their own key names.

### What must already exist (before you run the script)

The script only creates IAM roles and the OIDC provider. It does **not** create the S3 bucket or any other resources. Have the following in place before you run the script:

1. **S3 bucket for Terraform state**  
   The bucket whose name you put in `TF_BACKEND_BUCKET` must already exist. `TF_BACKEND_BUCKET` is just the shell variable name; the value should be your real S3 bucket name. The script grants the state role permission to read/write that bucket; it does not create the bucket. Create the bucket in the same account and region you will use for Terraform. Enable **versioning** on the bucket (recommended for Terraform state).
   
   S3 bucket naming rules to avoid common errors:
   - Use lowercase letters, numbers, and hyphens only.
   - Do not use uppercase letters or underscores.
   - Bucket names are globally unique across AWS, so you may need to pick a different name if one already exists.

   **Create the bucket:**
   - **Console:** S3 → **Create bucket** → choose a bucket name (this will be your `TF_BACKEND_BUCKET` value), select the correct region → **Create bucket**.
   - **CLI:** To run the commands below you need a terminal with the AWS CLI: **In AWS CloudShell** — click the **CloudShell** icon in the AWS Console top bar; the CLI is pre-installed and uses the account you're logged into. **On your own machine** — open a terminal (e.g. **Terminal** on macOS/Linux, **PowerShell** or **Command Prompt** on Windows), install the [AWS CLI](https://aws.amazon.com/cli/) if needed, and run `aws configure`. Then run (replace `BUCKET_NAME` and `REGION` with your values; for regions other than `us-east-1` you must set `--create-bucket-configuration LocationConstraint=REGION`):
     ```bash
     aws s3api create-bucket --bucket BUCKET_NAME --region REGION
     # If region is not us-east-1, use instead:
     # aws s3api create-bucket --bucket BUCKET_NAME --region REGION --create-bucket-configuration LocationConstraint=REGION
     ```

   **Enable versioning:**
   - **Console:** Open the bucket → **Properties** → **Bucket Versioning** → **Edit** → **Enable** → **Save changes**.
   - **CLI:** Run (replace `BUCKET_NAME` with your bucket name):
     ```bash
     aws s3api put-bucket-versioning --bucket BUCKET_NAME --versioning-configuration Status=Enabled
     ```

2. **AWS account in an Organization**  
   The state role trust policy uses `aws:PrincipalOrgID`, so your AWS account must be part of an **AWS Organization**. You will need the organization ID for the `AWS_ORGANIZATION_ID` variable (format looks like `o-xxxxxxxxxx`). If your account is standalone (not in an org), this trust condition will not work; use an account that is in an organization, or you would need to change the trust policy outside this script.

3. **Values for the required variables**  
   You need a value for each of the eight required environment variables. See [Required environment variables](#required-environment-variables-for-running-the-script) below for the full list, what each one means, and where to get the values (e.g. GitHub org/repo, AWS account ID, AWS Organization ID, S3 bucket name, and the three role names). The GitHub repo itself can exist before or after you run the script; the OIDC trust will apply to that org/repo once the workflow runs.

### Prerequisites to run the script

Before running the script, ensure:

1. **AWS environment**  
   You are in the AWS account where the roles should be created (e.g. open **AWS CloudShell** from that account, or have AWS credentials for that account configured).

2. **Python 3**  
   Available in AWS CloudShell by default. On your own machine, install Python 3.7+ if needed.

3. **boto3**  
   Install with: `pip install boto3` (CloudShell may already have it).

4. **IAM permissions**  
   The credentials you use must be allowed to:
   - Create/read the OIDC identity provider: `iam:CreateOpenIDConnectProvider`, `iam:GetOpenIDConnectProvider`
   - Create/update IAM roles and policies: `iam:CreateRole`, `iam:UpdateAssumeRolePolicy`, `iam:PutRolePolicy`, `iam:AttachRolePolicy`, `iam:GetRole`

   An IAM user or role with **AdministratorAccess** (or an equivalent custom policy with the above) is sufficient.

### Where to run it

- **AWS CloudShell** (recommended): Open it from the account where you want the roles; it has AWS credentials and Python. Install boto3 if needed (`pip install boto3`).
- Any environment where you have AWS credentials and Python 3 with boto3.

### Required environment variables (for running the script)

All of the following must be set (no defaults). The script exits with an error if any are missing.

Important:
- These are **shell environment variables** you set in CloudShell (or your terminal) right before running the Python script.
- These are **not** GitHub repository Variables/Secrets.
- After the script runs, copy the relevant values into GitHub **Secrets** in step 5.
- For exactly how to set them in your shell session, see step 3 in [Example: run in CloudShell](#example-run-in-cloudshell).

| Variable | Description | Where to get it |
|----------|-------------|-----------------|
| `TF_BACKEND_BUCKET` | S3 bucket name for Terraform state (same value you will set in GitHub as the `TF_BACKEND_BUCKET` secret). This is a variable name; set its value to your real bucket name. | Name of the S3 bucket you created (see step 1 above). |
| `GITHUB_ORG` | GitHub organization or user that owns the repo (no URL, just the name). | From the repo URL when you're on the repo main page: `https://github.com/ORG/REPO` → use the **ORG** part. |
| `GITHUB_REPO` | Repository name. | From the repo URL when you're on the repo main page: `https://github.com/ORG/REPO` → use the **REPO** part. |
| `AWS_ORGANIZATION_ID` | AWS Organizations ID (used in state role trust condition `aws:PrincipalOrgID`). | AWS Console → **Organizations**; or in **CloudShell** run: `aws organizations describe-organization --query Organization.Id --output text` (paste only the command, not the backticks, or you get "command not found"). |
| `AWS_ACCOUNT_ID` | AWS account ID (12-digit) where the roles are created. | AWS Console (top-right); or in **CloudShell** run: `aws sts get-caller-identity --query Account --output text` (paste only the command, not the backticks). |
| `GITHUB_ACTIONS_ROLE` | IAM role name for GitHub Actions (must match `SHARED_AWS_ROLE_NAME` in GitHub). | Any name you choose for this role. |
| `STATE_ROLE_NAME` | IAM role name for Terraform state bucket access. | Any name you choose for this role. |
| `TERRAFORM_EXEC_ROLE` | IAM role name for Terraform execution. | Any name you choose for this role. |

### Example: run in CloudShell

1. Open **AWS CloudShell** in the account where you want the roles (same account the workflow will use). In the AWS Console, click the **CloudShell** icon (terminal) in the top bar; wait for the session to start.  
   If the prompt shows `>` at the start of a line instead of `~ $`, the shell is stuck waiting for input (e.g. from a bad paste). Press **Ctrl+C** to cancel and get back to a normal `~ $` prompt.

2. Get the script into CloudShell (choose one):

   **Option A: Clone the repository**
   - In the CloudShell terminal, run (replace `YOUR_ORG` with the GitHub org or user that owns the repo you cloned):
     ```bash
     git clone https://github.com/YOUR_ORG/terraform-github-runner-ecs.git
     cd terraform-github-runner-ecs
     ```
   - The script is now at `scripts/setup-github-actions-iam.py`. In step 4 you will run: `python3 scripts/setup-github-actions-iam.py`.

  **Option B: Upload the script (no git)**  
  1. In GitHub, open `scripts/setup-github-actions-iam.py`.
  2. Click **Raw** and save it on your machine as `setup-github-actions-iam.py`.
  3. In CloudShell, open the **Actions** dropdown (sometimes shown as a gear icon), then click **Upload file**.
  4. Select your saved `setup-github-actions-iam.py` file and upload it.
  5. In the terminal, confirm the file is present (for example, `ls setup-github-actions-iam.py`).
  6. In step 4 below, run: `python3 setup-github-actions-iam.py` (no `scripts/` prefix).

3. Set all required environment variables in the terminal (replace with your values). These are temporary shell variables for the script run, not GitHub repo variables. See [Required environment variables](#required-environment-variables-for-running-the-script) for the full list and what each variable is.

   ```bash
   export TF_BACKEND_BUCKET=your-actual-s3-bucket-name
   export GITHUB_ORG=YOUR_GITHUB_ORG
   export GITHUB_REPO=YOUR_REPO_NAME
   export AWS_ORGANIZATION_ID=YOUR_ORG_ID
   export AWS_ACCOUNT_ID=YOUR_ACCOUNT_ID
   export GITHUB_ACTIONS_ROLE=YOUR_GITHUB_ACTIONS_ROLE_NAME
   export STATE_ROLE_NAME=YOUR_STATE_ROLE_NAME
   export TERRAFORM_EXEC_ROLE=YOUR_TERRAFORM_EXEC_ROLE_NAME
   ```

   You can paste the whole block into the CloudShell terminal; it will run as separate commands (one per line). **Replace each placeholder with your real values before pasting**—otherwise the script will see the placeholders. Edit the block in a text editor on your machine (e.g. Notepad or your IDE), then paste the edited block into the terminal.

4. Install boto3 (if needed) and run the script:
   - If you used **Option A** (cloned repo): `pip install boto3` then `python3 scripts/setup-github-actions-iam.py`
   - If you used **Option B** (created file manually): `pip install boto3` then `python3 setup-github-actions-iam.py`

   The script prints what it creates and, at the end, the values to use in GitHub. CloudShell may show a boto3 warning about Python 3.9; you can ignore it (Python 3.10+ is recommended where available).

5. In your GitHub repo, go to **Settings → Secrets and variables → Actions** and add (or update) these secrets. Use the exact values you used when running the script (no defaults):
   - `SHARED_AWS_ACCOUNT_ID` = the value you set for `AWS_ACCOUNT_ID` in step 3 (the script also prints it at the end).
   - `SHARED_AWS_ROLE_NAME` = the value you set for `GITHUB_ACTIONS_ROLE` in step 3.
   - `TF_BACKEND_BUCKET` = the value you set for `TF_BACKEND_BUCKET` in step 3.

The workflow uses `role-to-assume: arn:aws:iam::${{ secrets.SHARED_AWS_ACCOUNT_ID }}:role/${{ secrets.SHARED_AWS_ROLE_NAME }}`, so each GitHub secret must match the corresponding variable you used when running the script.
