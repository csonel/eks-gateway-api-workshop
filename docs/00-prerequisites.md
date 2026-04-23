# Prerequisites

Install the following tools before the workshop. All labs require these to be present and at the correct version.

> **Tip:** Run `scripts/setup.sh` (Linux/macOS) or `scripts/setup.ps1` (Windows) to install all prerequisites automatically. The script skips tools that are already installed at the required version. Use `--check` to verify readiness without installing anything.

> **Note:** This repository includes a [`.terraform-version`](../.terraform-version) file for users of Terraform version managers such as `tfenv`/`asdf`. The setup scripts use their own pinned version and do not depend on this file.

## Required Tools

| Tool      | Minimum Version | Install                                                                         |
|-----------|-----------------|---------------------------------------------------------------------------------|
| AWS CLI   | v2.x            | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html   |
| kubectl   | v1.35+          | https://kubernetes.io/docs/tasks/tools/                                         |
| Helm      | v3.14+          | https://helm.sh/docs/intro/install/                                             |
| Terraform | v1.12+          | https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli |

## Optional Tools

| Tool   | Minimum Version | Install                         | Notes                                                         |
|--------|-----------------|---------------------------------|---------------------------------------------------------------|
| eksctl | v0.198.0+       | https://eksctl.io/installation/ | Useful for cluster administration tasks outside the workshop. |

## AWS Credentials

You need an AWS account and valid credentials to provision the EKS cluster using the Terraform code in this repository. Configure a named profile or use environment variables. Pick whichever method you prefer.

**Option A: Named profile** (recommended if you have multiple AWS accounts):

```bash
aws configure --profile aws-community-day
```

Then export it so all commands in this terminal use it automatically:

```bash
export AWS_PROFILE=aws-community-day
```

PowerShell (Windows):

```powershell
$env:AWS_PROFILE = "aws-community-day"
```

**Option B: Environment variables:**

```bash
export AWS_ACCESS_KEY_ID=<your-key>
export AWS_SECRET_ACCESS_KEY=<your-secret>
export AWS_DEFAULT_REGION=eu-central-1
```

PowerShell (Windows):

```powershell
$env:AWS_ACCESS_KEY_ID="<your-key>"
$env:AWS_SECRET_ACCESS_KEY="<your-secret>"
$env:AWS_DEFAULT_REGION="eu-central-1"
```

> **Terraform note:** The Terraform configuration uses a named profile (`aws-community-day`) in `terraform.tfvars`. If you use environment variables instead of a named profile, override the profile variable when running Terraform commands:
>
> ```bash
> terraform plan -var='profile='
> terraform apply -var='profile='
> ```
>
> PowerShell (Windows):
>
> ```powershell
> terraform plan -var 'profile='
> terraform apply -var 'profile='
> ```
>
> Alternatively, edit `terraform.tfvars` and set `profile = ""` before running any Terraform commands.

**Option C: SSO:**

```bash
aws sso login --profile aws-community-day
export AWS_PROFILE=aws-community-day
```

PowerShell (Windows):

```powershell
aws sso login --profile aws-community-day
$env:AWS_PROFILE = "aws-community-day"
```

### Verify Access

```bash
aws sts get-caller-identity
```

Expected output: a JSON object showing your `UserId`, `Account`, and `Arn`. Confirm the `Account` field matches the AWS account you intend to use. If you see an error, check your credentials before proceeding.

## Verify Tool Versions

```bash
aws --version
kubectl version --client
helm version
eksctl version
```

Once all tools are installed and credentials are working, you are ready to connect to the cluster.

## Next Step

Continue to [01-setup.md](01-setup.md) to connect to the workshop cluster.
