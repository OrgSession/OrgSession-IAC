# Execution Guide: OrgSession CI/CD POC

This guide walks through deploying the OrgSession System Status Dashboard from scratch. Follow the steps in order.

---

## Prerequisites

Install the following tools before starting:

| Tool | Version | Install Guide |
|------|---------|---------------|
| AWS CLI | v2 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Terraform | >= 1.7 | https://developer.hashicorp.com/terraform/install |
| Docker | Latest | https://docs.docker.com/get-docker/ |
| Node.js | >= 20 | https://nodejs.org/ |
| Python | >= 3.12 | https://www.python.org/downloads/ |
| jq | Latest | https://jqlang.github.io/jq/download/ |
| git | Latest | https://git-scm.com/downloads |

You also need:

- An AWS account with administrator access (for initial setup)
- A GitHub account with access to the three OrgSession repositories
- AWS CLI configured: `aws configure` with your access key, secret, and region `us-east-1`

---

## Branch and Environment Mapping

All three repositories follow the same branching convention:

| Branch | Environment |
|--------|-------------|
| `development` | dev |
| `main` | prod |

**Pull requests to `development`** trigger validation workflows (plan, test, build check).
**Pull requests to `main`** trigger validation workflows targeting the prod environment.
**Merging to `development`** deploys to dev.
**Merging to `main`** deploys to prod (with a required reviewer gate on the GitHub Environment).

---

## Step 1: Bootstrap AWS Resources

These resources are created once, manually. They support all Terraform state management.

### 1.1 Create the Terraform state S3 bucket

```bash
aws s3api create-bucket \
  --bucket github-session-my-org-terraform-state \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket github-session-my-org-terraform-state \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket github-session-my-org-terraform-state \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

aws s3api put-public-access-block \
  --bucket github-session-my-org-terraform-state \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### 1.2 Create the DynamoDB lock table

```bash
aws dynamodb create-table \
  --table-name github-session-my-org-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 1.3 Create the GitHub Actions IAM user

```bash
aws iam create-user --user-name github-actions-orgsession
```

Attach the required policies:

```bash
# ECS and ECR
aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess

# S3 and CloudFront
aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/CloudFrontFullAccess

# Secrets Manager
aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite

# Infrastructure (for Terraform)
aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/AmazonVPCFullAccess

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/IAMFullAccess

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess
```

### 1.4 Create access keys for the IAM user

```bash
aws iam create-access-key \
  --user-name github-actions-orgsession \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' \
  --output text
```

The output is two values on one line: the access key ID and the secret access key. Save both. You will add them as GitHub secrets in the next step.

---

## Step 2: Configure GitHub Repository Secrets

For each of the three repositories (OrgSession-IAC, OrgSession-BE, OrgSession-FE), add the following secrets via GitHub Settings > Secrets and variables > Actions:

| Secret Name | Value |
|-------------|-------|
| `AWS_ACCESS_KEY_ID` | The access key ID from Step 1.4 |
| `AWS_SECRET_ACCESS_KEY` | The secret access key from Step 1.4 |
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |

To add secrets using the GitHub CLI (run once per repo):

```bash
# Replace YOUR_ACCESS_KEY_ID, YOUR_SECRET_ACCESS_KEY, YOUR_ACCOUNT_ID
# Replace YOUR_GITHUB_ORG with your GitHub org or username

for REPO in OrgSession-IAC OrgSession-BE OrgSession-FE; do
  gh secret set AWS_ACCESS_KEY_ID \
    --body "YOUR_ACCESS_KEY_ID" \
    --repo YOUR_GITHUB_ORG/$REPO

  gh secret set AWS_SECRET_ACCESS_KEY \
    --body "YOUR_SECRET_ACCESS_KEY" \
    --repo YOUR_GITHUB_ORG/$REPO

  gh secret set AWS_ACCOUNT_ID \
    --body "YOUR_ACCOUNT_ID" \
    --repo YOUR_GITHUB_ORG/$REPO
done
```

---

## Step 3: Configure GitHub Environments

In the `OrgSession-IAC` repository, create two GitHub Environments for deployment gates:

1. Go to Settings > Environments > New environment
2. Create `dev` (no protection rules needed for auto-deploy)
3. Create `prod` and add a required reviewer (yourself or a team member)

This ensures `terraform apply` for production requires manual approval.

---

## Step 4: Deploy Infrastructure (OrgSession-IAC)

### 4.1 Create a feature branch and push

```bash
cd OrgSession-IAC
git checkout -b feature/initial-infrastructure
git add .
git commit -m "Initial Terraform infrastructure"
git push origin feature/initial-infrastructure
```

### 4.2 Open a pull request to `development`

Open a PR from `feature/initial-infrastructure` to `development` on GitHub. The `terraform-plan.yml` workflow will run automatically and:

- Run `terraform init`, `validate`, and `plan` for the dev environment
- Post the plan output as a comment on the PR
- Upload the plan as a workflow artifact

Review the plan output in the PR comments. Verify it shows resources to create (VPC, subnets, ECR, ECS, ALB, S3, CloudFront, Secrets Manager).

### 4.3 Merge to `development` (deploys dev)

After reviewing the plan, merge the PR to `development`. The `terraform-apply.yml` workflow runs automatically and applies the dev environment. This uses the `dev` GitHub Environment -- no manual approval required.

Infrastructure provisioning takes approximately 10-15 minutes (CloudFront distribution takes the longest).

### 4.4 Promote to `main` (deploys prod)

When ready to deploy prod, open a PR from `development` to `main`. The plan workflow runs targeting the prod environment. After review, merge to `main`. The apply workflow runs for the `prod` GitHub Environment -- which requires your configured required reviewer to approve before Terraform runs.

### 4.5 Verify infrastructure outputs

After the apply completes, check the Terraform outputs:

```bash
cd OrgSession-IAC/environments/dev
terraform init
terraform output
```

Note the values for:
- `alb_dns_name` - the backend endpoint
- `cloudfront_domain_name` - the frontend URL
- `ecr_repository_url` - where Docker images are pushed

---

## Step 5: Deploy the Backend (OrgSession-BE)

### 5.1 Open a PR and deploy to dev

```bash
cd OrgSession-BE
git checkout -b feature/initial-backend
git add .
git commit -m "Initial FastAPI backend"
git push origin feature/initial-backend
```

Open a PR to `development`. The `PR Checks` workflow runs tests and verifies the Docker build. Merge to `development` when checks pass.

### 5.2 Monitor the deploy workflow

In GitHub Actions, watch the `Deploy Backend` workflow for the `development` branch:

1. Tests run first
2. ECR repository name, ECS cluster, and ECS service are read from Secrets Manager (`orgsession/dev/config`)
3. Docker image is built and pushed to ECR (tagged with commit SHA and `latest`)
4. ECS service is updated with `--force-new-deployment`
5. Workflow waits for the ECS service to stabilize (typically 2-3 minutes)

### 5.3 Verify the backend

Once deployed, test the endpoint:

```bash
ALB_DNS=$(cd OrgSession-IAC/environments/dev && terraform output -raw alb_dns_name)
curl http://$ALB_DNS/status
```

Expected response:

```json
{
  "app_name": "OrgWide Session Demo",
  "version": "v1",
  "environment": "dev",
  "status": "All systems operational",
  "timestamp": "2026-04-01T10:00:00.123456+00:00"
}
```

---

## Step 6: Deploy the Frontend (OrgSession-FE)

### 6.1 Open a PR and deploy to dev

```bash
cd OrgSession-FE
git checkout -b feature/initial-frontend
git add .
git commit -m "Initial React dashboard"
git push origin feature/initial-frontend
```

Open a PR to `development`. The `PR Checks` workflow builds the React app with a placeholder API URL to verify the build succeeds. Merge to `development` when checks pass.

### 6.2 Monitor the deploy workflow

The `Deploy Frontend` workflow for the `development` branch:

1. Reads the API URL, S3 bucket name, and CloudFront distribution ID from Secrets Manager (`orgsession/dev/config`)
2. Builds the React app with `VITE_API_URL` set to the actual ALB DNS name
3. Syncs the built files to S3
4. Creates a CloudFront invalidation so edge caches are immediately cleared

### 6.3 Verify the frontend

Open the CloudFront URL in a browser:

```bash
CF_DOMAIN=$(cd OrgSession-IAC/environments/dev && terraform output -raw cloudfront_domain_name)
echo "https://$CF_DOMAIN"
```

The dashboard should display:
- App name: OrgWide Session Demo
- Version: v1 (highlighted in blue)
- Environment: dev badge
- Status: All systems operational (with pulsing dot)
- Timestamp from the backend

---

## Step 7: Demonstrate the CI/CD Pipeline

This step shows how a code change flows through the pipeline.

### 7.1 Update the backend version

In `OrgSession-BE/app/config.py`, change:

```python
VERSION = "v1"
```

to:

```python
VERSION = "v2"
```

Optionally update the status message in `app/main.py`:

```python
"status": "v2 deployed successfully",
```

### 7.2 Push the change

```bash
cd OrgSession-BE
git checkout development
git add app/config.py app/main.py
git commit -m "Bump version to v2"
git push origin development
```

### 7.3 Watch the pipeline and verify

1. Watch the GitHub Actions workflow in the browser
2. After the workflow completes, wait 30 seconds for ECS to fully replace tasks
3. Refresh the frontend dashboard
4. The version card should now show `v2`

---

## Teardown

To avoid ongoing AWS charges after the demo, destroy all resources in reverse order.

### Destroy dev environment

```bash
cd OrgSession-IAC/environments/dev
terraform init
terraform destroy -var="aws_account_id=YOUR_ACCOUNT_ID"
```

Type `yes` when prompted. This takes 10-15 minutes.

### Destroy prod environment

```bash
cd OrgSession-IAC/environments/prod
terraform init
terraform destroy -var="aws_account_id=YOUR_ACCOUNT_ID"
```

### Remove bootstrap resources

```bash
# Delete all objects from S3 state bucket first
aws s3 rm s3://github-session-my-org-terraform-state --recursive

# Delete the bucket
aws s3api delete-bucket --bucket github-session-my-org-terraform-state

# Delete the DynamoDB table
aws dynamodb delete-table --table-name github-session-my-org-terraform-locks

# Delete the IAM user access keys
KEY_IDS=$(aws iam list-access-keys \
  --user-name github-actions-orgsession \
  --query 'AccessKeyMetadata[].AccessKeyId' \
  --output text)
for KEY_ID in $KEY_IDS; do
  aws iam delete-access-key \
    --user-name github-actions-orgsession \
    --access-key-id "$KEY_ID"
done

# Detach all policies then delete the IAM user
for POLICY_ARN in \
  arn:aws:iam::aws:policy/AmazonECS_FullAccess \
  arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess \
  arn:aws:iam::aws:policy/AmazonS3FullAccess \
  arn:aws:iam::aws:policy/CloudFrontFullAccess \
  arn:aws:iam::aws:policy/SecretsManagerReadWrite \
  arn:aws:iam::aws:policy/AmazonVPCFullAccess \
  arn:aws:iam::aws:policy/IAMFullAccess \
  arn:aws:iam::aws:policy/CloudWatchLogsFullAccess \
  arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess; do
  aws iam detach-user-policy \
    --user-name github-actions-orgsession \
    --policy-arn "$POLICY_ARN"
done
aws iam delete-user --user-name github-actions-orgsession
```

---

## Troubleshooting

### AWS credential errors (InvalidClientTokenId or AccessDenied)

Symptom: GitHub Actions fails with `InvalidClientTokenId` or `User is not authorized to perform`

Check:
1. `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are set correctly in GitHub secrets with no extra spaces
2. The IAM user `github-actions-orgsession` exists: `aws iam get-user --user-name github-actions-orgsession`
3. The access key is active: `aws iam list-access-keys --user-name github-actions-orgsession`
4. The required policies are attached: `aws iam list-attached-user-policies --user-name github-actions-orgsession`
5. If the access key was recently created, wait 30-60 seconds for IAM propagation

### ECS service stuck in deployment

Symptom: The `aws ecs wait services-stable` step times out

Check:
1. CloudWatch Logs at `/ecs/orgsession-be-dev` for container startup errors
2. ALB target group health checks - the `/status` endpoint must return HTTP 200
3. Security group rules - ECS tasks must allow inbound on port 8000 from the ALB security group

### CORS errors in browser

Symptom: Dashboard shows error, browser console shows `CORS policy` error

Check:
1. The ECS task `CORS_ORIGINS` environment variable matches the exact CloudFront domain including `https://`
2. Terraform output for `cloudfront_domain_name` matches what the ECS task received
3. Redeploy the ECS service after confirming the environment variable is correct

### CloudFront serving stale content

Symptom: Frontend shows old version after a deploy

The deploy workflow creates a `/*` invalidation automatically. If the issue persists:

```bash
CF_DIST_ID=$(cd OrgSession-IAC/environments/dev && terraform output -raw cloudfront_distribution_id)
aws cloudfront create-invalidation \
  --distribution-id "$CF_DIST_ID" \
  --paths "/*"
```

### Terraform state lock

Symptom: `Error acquiring the state lock`

If a previous operation was interrupted:

```bash
aws dynamodb delete-item \
  --table-name github-session-my-org-terraform-locks \
  --key '{"LockID": {"S": "github-session-my-org-terraform-state/orgsession/dev/terraform.tfstate-md5"}}'
```

Replace the key with the one shown in the error message.
