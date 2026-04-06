# Presentation Walkthrough: OrgSession CI/CD POC

## Audience

Senior engineers, architects, and technical leads evaluating CI/CD patterns for AWS-based workloads.

---

## 1. Architecture Overview

### System Diagram

```
Developer Workstation
        |
        | git push / pull request
        v
GitHub (3 Repositories)
  |               |                |
  v               v                v
OrgSession-IAC  OrgSession-BE   OrgSession-FE
(Terraform)     (FastAPI)       (React/Vite)
  |               |                |
  v               v                v
GitHub Actions  GitHub Actions  GitHub Actions
  |               |                |
  v               v                v
AWS              ECR ->          S3 +
Infrastructure   ECS Fargate     CloudFront
                      |               |
                      v               v
                     ALB         CloudFront
                      |          Distribution
                      |               |
                      |    /status    |    /*
                      +<--------------+----+
                                      |
                               Browser Request
                               https://cf-domain/status  -> CloudFront -> ALB -> ECS
                               https://cf-domain/         -> CloudFront -> S3
```

### Dual-Origin CloudFront Routing

CloudFront is configured with two origins:

- **S3 origin** (default behavior, `/*`): serves the React static bundle with caching
- **ALB origin** (ordered behavior, `/status`): proxies API requests to ECS, TTL=0 (no caching)

This means the browser talks only to CloudFront over HTTPS for both the frontend and the API. CloudFront forwards `/status` to the ALB over HTTP internally on the private network. There is no mixed content issue and no CORS requirement because all browser requests go to the same origin.

### Component Responsibilities

**OrgSession-IAC** defines all AWS infrastructure as Terraform code. It is the source of truth for every cloud resource. Changes to infrastructure go through the same PR review and pipeline as application code.

**OrgSession-BE** contains a minimal FastAPI service with a single `/status` endpoint. It is containerized with Docker and deployed to ECS Fargate behind an Application Load Balancer. The ALB is not directly reachable by the browser -- requests arrive via CloudFront.

**OrgSession-FE** contains a React/Vite single-page application. It calls `/status` on the same CloudFront domain and renders the response in a dashboard. It is deployed as a static site to S3, served globally through CloudFront.

**AWS Secrets Manager** holds the full deployment configuration for each environment: the HTTPS CloudFront URL (used as the API URL), S3 bucket name, CloudFront distribution ID, ECR repository details, and ECS cluster and service names. Both the backend and frontend CI/CD pipelines read from this secret at runtime. No resource names are hardcoded in workflow files.

---

## 2. CI/CD Workflow Explanation

### Branch and Environment Convention

All three repositories share the same convention: the `development` branch deploys to the dev environment, and the `main` branch deploys to prod. This makes the relationship between code state and deployed state immediately readable from the branch name.

PRs to `development` trigger validation against dev. PRs to `main` trigger validation against prod. The promotion path for any change is: feature branch -> PR to `development` -> merge -> PR to `main` -> merge with required reviewer approval.

### Infrastructure Pipeline (OrgSession-IAC)

**Pull Request trigger:**

When a developer opens a PR, GitHub Actions inspects the target branch (`github.base_ref`) to determine which environment to plan. A PR to `development` plans the dev environment; a PR to `main` plans prod. The plan output is posted as a comment on the PR, making infrastructure changes visible to reviewers before any resource is modified.

**Merge trigger:**

On merge to `development`, `terraform apply` runs for dev automatically using the `dev` GitHub Environment. On merge to `main`, it runs for prod using the `prod` GitHub Environment -- which has a required reviewer configured, requiring a human to approve before Terraform touches production resources.

### Backend Pipeline (OrgSession-BE)

**Pull Request trigger:**

A PR to `development` or `main` triggers the `build` workflow, which runs the pytest suite and verifies the Docker image builds successfully. No deployment occurs on a PR. Tests use a separate `requirements-dev.txt` that includes pytest and httpx; the production `requirements.txt` contains only fastapi and uvicorn.

**Merge trigger:**

On merge, the `deploy` workflow reads the target environment from the branch name. It fetches the ECR repository name, ECS cluster name, and ECS service name from Secrets Manager (`orgsession/dev/config` or `orgsession/prod/config`). This means the workflow contains no hardcoded resource names -- all deployment targets are resolved at runtime.

The pipeline runs tests, builds a Docker image, and pushes it to ECR tagged with both the git commit SHA and `latest`. Then it registers a new ECS task definition revision:

1. Fetch the current task definition from ECS
2. Reconstruct a new task definition JSON by selecting only the writable fields (family, roles, network mode, cpu, memory, container definitions)
3. Replace the container image in `containerDefinitions` with the new ECR image URI
4. Register the new task definition revision via `aws ecs register-task-definition`
5. Update the ECS service to the new revision via `aws ecs update-service --task-definition`
6. Wait for the service to stabilize via `aws ecs wait services-stable`

This approach guarantees that ECS uses the exact image that was just pushed, identified by commit SHA. It avoids the `--force-new-deployment` pattern, which can re-pull the `latest` tag without guaranteeing which image version ECS actually runs.

### Frontend Pipeline (OrgSession-FE)

**Pull Request trigger:**

A PR to `development` or `main` triggers the `build` workflow, which runs `npm ci` and `npm run build` with a placeholder API URL. This verifies the build toolchain and all imports resolve correctly without connecting to any real backend.

**Merge trigger:**

On merge, the `deploy` workflow reads three values from Secrets Manager: the HTTPS CloudFront URL (used as the API URL), the S3 bucket name, and the CloudFront distribution ID. These were written there by Terraform during infrastructure provisioning.

The pipeline builds the Vite bundle with `VITE_API_URL` set to the HTTPS CloudFront URL. Because the frontend and the `/status` endpoint are both served from the same CloudFront domain, this is a same-origin request with no CORS headers needed. The built files are synced to S3 and the CloudFront distribution cache is invalidated.

The CloudFront invalidation is critical. Without it, users on edge nodes that have cached the old `index.html` would continue to see the previous version until the TTL expires. The `/*` invalidation forces all edge locations to fetch fresh content on the next request.

---

## 3. Key Technical Decisions and Trade-offs

### Terraform Wrapper Pattern vs Workspaces

**Decision:** Directory-based environment separation (`environments/dev`, `environments/prod`) rather than Terraform workspaces.

**Reasoning:**

Terraform workspaces share a single configuration and vary behavior through workspace-specific variable files. The wrapper pattern uses separate directory trees that each call shared modules with environment-specific values.

Workspaces are convenient for small differences between environments (a replica count, an instance size). They become fragile when environments diverge structurally, when you need to run operations on one environment without touching another, or when you want to review the exact plan for a specific environment without switching context.

The wrapper pattern makes the state isolation explicit (each directory has its own backend config, its own state key), makes environment-specific customization explicit in the module call arguments, and makes it impossible to accidentally apply to the wrong environment.

**Trade-off:** More file duplication. The `prod` directory is almost identical to `dev`. This is acceptable because the duplication is in configuration (values), not in logic (which lives in modules).

### AWS Authentication: IAM User Access Keys

**Decision:** GitHub Actions authenticates to AWS using a dedicated IAM user with static access keys stored as GitHub repository secrets.

**Reasoning:**

This is the most straightforward approach for a POC and is universally supported across all GitHub plans and AWS account types. A dedicated IAM user (`github-actions-orgsession`) is created with only the policies required for the deployment workflows. The access key ID and secret are stored as GitHub secrets, which are encrypted at rest and masked in workflow logs.

**Trade-off:** Access keys are long-lived credentials that must be rotated periodically and revoked if a repository is compromised. The production hardening path is to replace this with OIDC, which eliminates the static secret entirely by issuing short-lived credentials per workflow run. For this POC, access keys are the right balance of simplicity and control.

**Rotation procedure:** To rotate the key, create a new access key for the IAM user, update the GitHub secrets in all three repos, then delete the old key.

### CloudFront as API Proxy

**Decision:** Route all browser-facing API calls through CloudFront (`/status`) rather than directly to the ALB.

**Reasoning:**

The frontend is served over HTTPS from CloudFront. If the browser were to call the ALB directly over HTTP, browsers would block it as a mixed content violation -- an HTTPS page is not permitted to make HTTP subrequests. The two available remedies are: (1) put an ACM certificate on the ALB and use HTTPS end-to-end, or (2) proxy the API call through CloudFront so the browser only ever talks HTTPS to one domain.

Option 2 costs nothing extra (CloudFront is already deployed) and eliminates the ALB HTTPS setup, ACM certificate provisioning, and custom domain requirements. It also removes the CORS requirement entirely: because both the page and the API call go to the same CloudFront domain, the browser treats it as a same-origin request.

CloudFront is configured with a separate ordered cache behavior for the `/status` path with TTL=0. This ensures the browser always gets a live response from ECS, not a cached CloudFront response.

**Trade-off:** The ALB is still HTTP-only. Traffic from CloudFront to the ALB is unencrypted inside the AWS network. For a POC this is acceptable. Production hardening would add an ACM certificate to the ALB and change the CloudFront origin protocol to HTTPS-only.

### ECS Fargate vs EC2 vs Lambda

**Decision:** ECS Fargate for the backend service.

**Reasoning:**

EC2 requires managing the underlying instances (patching, capacity planning, AMI selection). For a container workload, this is unnecessary operational overhead.

Lambda is a strong choice for stateless HTTP functions, but FastAPI with uvicorn is a persistent HTTP server. While Lambda does support containerized workloads, the cold start behavior and execution model differences make it a poor fit for a service that needs consistent sub-100ms response times.

Fargate runs the container without managing servers. You define CPU and memory, Fargate handles the rest. The ECS service handles health checking, rolling deployments, and task replacement.

**Trade-off:** Higher baseline cost than Lambda for low-traffic workloads. A Fargate task with 256 CPU / 512 MiB running continuously costs approximately $9/month. A Lambda that only runs when called costs fractions of a cent for low traffic.

### S3 + CloudFront vs Amplify vs App Runner

**Decision:** S3 with CloudFront for the frontend.

**Reasoning:**

AWS Amplify hosting automates much of this, but it is a higher-level abstraction that obscures the underlying components. For a POC demonstrating how CI/CD and infrastructure work, showing the explicit components (S3 bucket, OAC policy, CloudFront distribution) is more educational and more representative of how production frontend infrastructure is actually built.

App Runner is designed for containerized applications, not static sites.

S3 + CloudFront is the industry standard for serving static sites at scale. It is globally distributed, highly available, and requires no server management.

**Trade-off:** More Terraform and more workflow steps compared to Amplify. The operational model is explicit but verbose.

### Container Image Tagging and Deployment Strategy

**Decision:** Tag images with both the git commit SHA and `latest`. Deploy by registering a new task definition revision with the SHA-tagged image, then updating the ECS service to that revision.

**Reasoning:**

The SHA tag is immutable and traceable. If you look at a running ECS task, you can read the image tag and find the exact commit that produced it. This is essential for debugging production issues.

Registering a new task definition revision (rather than using `--force-new-deployment` with `latest`) guarantees that ECS runs exactly the image that was just built and verified in the same pipeline run. With `--force-new-deployment`, ECS re-pulls `latest` from ECR -- there is a window where a concurrent push from another workflow could change what `latest` points to.

The registration approach also creates an auditable revision history in ECS. Rolling back to a previous version is a single `aws ecs update-service --task-definition <previous-arn>` command.

The `jq` reconstruction selects only the writable fields (family, roles, network mode, cpu, memory, volumes, container definitions) rather than deleting known read-only fields. This is more resilient: AWS can add new read-only fields to a task definition without breaking the pipeline.

---

## 4. Demo Flow and Narrative

### Setup context

"We have three repositories. One for infrastructure, one for the backend service, and one for the frontend. Each deploys independently through its own pipeline. Changes to infrastructure go through a review process identical to code review."

### Show the running system

"The frontend is running at this CloudFront URL. It calls our FastAPI backend through the same CloudFront domain -- the `/status` path is proxied through to ECS. All of this was provisioned by Terraform and deployed by GitHub Actions."

Point to: app name, version badge (v1), environment badge (dev), status indicator, timestamp updating.

### Show the pipeline trigger

Open `OrgSession-BE/app/config.py`. Change `VERSION = "v1"` to `VERSION = "v2"`.

"I am going to make a single-line change to the backend: bump the version to v2. I will push to the `development` branch, which deploys to the dev environment."

```bash
git add app/config.py
git commit -m "Bump version to v2"
git push origin development
```

### Walk through the pipeline stages

In GitHub Actions, show the running `deploy` workflow:

1. "Tests run first. No deployment happens if tests fail."
2. "Docker builds the image, tags it with the commit SHA and latest, and pushes to ECR."
3. "The pipeline fetches the current task definition from ECS, reconstructs it with the new image, and registers a new task definition revision."
4. "ECS updates the service to use the new revision and begins a rolling replacement of tasks."
5. "The pipeline waits for ECS to stabilize before declaring success."

### Show the result

After the workflow completes (~3-4 minutes), refresh the frontend dashboard.

"The version card now shows v2. The entire change from commit to live went through an automated pipeline. No manual steps on any server. No SSH. No manual Docker commands. The infrastructure is unchanged. Only the application layer updated."

### Show the infrastructure gate

"If I had made a change to Terraform instead, the pipeline would have run plan, posted the plan to the PR as a comment, and waited for code review before applying. Merging to `main` for production would require an additional human approval step in the GitHub Environment."

---

## 5. Common Questions and Responses

**Q: How do you handle secrets in the application?**

A: There are two layers. GitHub Actions uses static IAM access keys stored as GitHub secrets -- these are encrypted, masked in logs, and scoped to a dedicated IAM user. All deployment configuration (CloudFront URL, S3 bucket name, ECS service name, ECR repo name) is stored in AWS Secrets Manager by Terraform after provisioning. Workflows read these values at runtime so no resource names are hardcoded in workflow files. The backend reads its application configuration through environment variables injected by ECS at container startup. No secrets appear in source code.

**Q: How do you avoid the mixed content error (HTTPS page calling HTTP API)?**

A: CloudFront is configured with two origins. The S3 origin handles all static asset requests (`/*`). The ALB origin handles API requests (`/status`) with an ordered cache behavior at TTL=0. The browser always sends requests to the same CloudFront HTTPS domain -- it never directly touches the HTTP ALB. CloudFront proxies `/status` to the ALB over HTTP internally on the AWS network. This approach avoids both the mixed content violation and any CORS requirements (since page and API share the same origin). The trade-off is that CloudFront-to-ALB traffic is unencrypted; adding an ACM certificate to the ALB would close that gap in production.

**Q: How do you roll back a bad deployment?**

A: For the backend, each push registers a new ECS task definition revision. Rolling back is a single command: `aws ecs update-service --cluster <cluster> --service <service> --task-definition <previous-revision-arn>`. ECS retains all previous revisions. For the frontend, S3 bucket versioning is enabled, so you can restore previous object versions. CloudFront cache is invalidated on each deploy, so rolling S3 back takes effect on the next request.

**Q: How would you make this production-ready?**

A: Several hardening steps beyond this POC: add an ACM certificate to the ALB and change the CloudFront origin protocol to HTTPS-only (eliminating unencrypted CloudFront-to-ALB traffic); add a custom domain on CloudFront with its own ACM certificate; add WAF rules on CloudFront and the ALB; implement ECS auto-scaling based on ALB request count; add a blue/green deployment strategy using CodeDeploy with ECS to enable zero-downtime deploys with automated rollback on health check failure; add structured logging and metrics to CloudWatch; set up alerting on ECS task failure and ALB 5xx rate; replace static IAM access keys with OIDC for GitHub Actions authentication.

**Q: Why not use AWS CodePipeline instead of GitHub Actions?**

A: GitHub Actions colocates the pipeline definition with the code in the same repository. Developers see the workflow file when they review code, which makes it easy to understand what happens when a change merges. CodePipeline is a strong choice when you need deep AWS service integrations or are operating in an environment where keeping everything inside AWS is a compliance requirement. For a cross-org CI/CD standard, GitHub Actions tends to be more portable and familiar to engineers coming from different cloud backgrounds.

**Q: How do dev and prod share the same ECR repository?**

A: They do not. Each environment has its own ECR repository: `orgsession-be-dev` and `orgsession-be-prod`. The backend CI/CD workflow reads the ECR repository URL from Secrets Manager at runtime. The dev secret points to the dev ECR repo; the prod secret points to the prod ECR repo. This isolation ensures a dev image push cannot accidentally affect the production service.

**Q: What does the Terraform wrapper pattern protect against?**

A: It prevents the most common Terraform production incident: running `terraform apply` in the wrong environment. With workspaces, switching environments is a `terraform workspace select` command, which is easy to forget or mistype. With directory-based separation, you must physically change to the correct directory. The state keys are different, the variable files are different, and the backend configuration is separate. There is no single command that can accidentally apply a dev change to prod.

---

## 6. Cost Estimate (dev environment, us-east-1, 30 days)

| Resource | Approximate Monthly Cost |
|----------|--------------------------|
| NAT Gateway (1) | $32 |
| Application Load Balancer | $16 |
| ECS Fargate (256 CPU / 512 MiB, always on) | $9 |
| ECR (storage, minimal) | $1 |
| CloudFront (free tier, low traffic) | $0 |
| S3 (static site, minimal) | $1 |
| Secrets Manager (1 secret) | $0.40 |
| CloudWatch Logs | $1 |
| **Total** | **~$60/month** |

The NAT Gateway is the largest cost item. For a short-lived POC, you can eliminate it by placing ECS tasks in public subnets with `assign_public_ip = true`. This trades a minor security boundary for $32/month in savings. For any real workload, keep ECS in private subnets.

---

## 7. Production Hardening Roadmap

The following items are out of scope for this POC but represent the path to production readiness:

1. **ALB HTTPS**: ACM certificate on the ALB listener; update CloudFront origin protocol to HTTPS-only to encrypt CloudFront-to-ALB traffic
2. **Custom domains**: Route 53 hosted zone, ALB alias record, CloudFront CNAME with ACM certificate
3. **OIDC for GitHub Actions**: Replace static IAM access keys with OIDC federation; short-lived credentials per workflow run, no rotation required
4. **WAF**: AWS WAF on CloudFront and ALB with managed rule groups for OWASP Top 10
5. **Blue/green deployments**: CodeDeploy + ECS for zero-downtime deploys with automatic rollback on health check failure
6. **Auto-scaling**: ECS service auto-scaling based on ALB RequestCountPerTarget
7. **Multi-AZ redundancy**: Increase ECS desired count to at least 2, spread across AZs
8. **Centralized logging**: Structured JSON logs from FastAPI, aggregated in CloudWatch
9. **Alerting**: CloudWatch Alarms on ALB 5xx rate, ECS task failure count, and target response time
10. **Container image scanning**: Enable ECR scan-on-push and fail CI if critical vulnerabilities are found
11. **Least-privilege IAM**: Replace managed policies on the GitHub Actions role with a scoped custom policy
12. **Multi-region**: Route 53 latency-based routing with ECS clusters in two regions
