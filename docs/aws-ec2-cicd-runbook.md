# MedRAG AWS EC2 CI/CD Runbook

This is the CLI-first guide for the full MedRAG production lifecycle:

1. bootstrap AWS infrastructure with `aws`
2. configure GitHub Actions with `gh`
3. deploy the app through CI/CD
4. test the live system
5. destroy everything completely

This guide matches the production assets already in this repo:

- [infra/cloudformation/medrag-prod.yml](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/infra/cloudformation/medrag-prod.yml)
- [.github/workflows/infrastructure.yml](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/.github/workflows/infrastructure.yml)
- [.github/workflows/deploy-prod.yml](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/.github/workflows/deploy-prod.yml)
- [.github/workflows/destroy-prod.yml](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/.github/workflows/destroy-prod.yml)
- [docker-compose.prod.yml](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/docker-compose.prod.yml)
- [scripts/deploy-prod.sh](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/scripts/deploy-prod.sh)
- [scripts/destroy-prod.sh](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/scripts/destroy-prod.sh)

## 1. Prerequisites

Install these CLIs on your machine:

- AWS CLI v2
- GitHub CLI (`gh`)
- `jq`
- `git`
- `curl`

You also need:

- AWS credentials with permission to create IAM, EC2, S3, ECR, Secrets Manager, and CloudFormation resources for the initial bootstrap
- admin access to the GitHub repository
- one `OPENAI_API_KEY`
- one `LLAMA_CLOUD_API_KEY`

Important distinction:

- the deployed app uses AWS Secrets Manager
- the current `Evaluation` workflow still uses GitHub repository secrets for CI evals before deploy

So this setup uses:

- AWS Secrets Manager for runtime secrets
- GitHub repository secrets for the CI eval job

Important safety rule:

- `AWS_BOOTSTRAP_ROLE_ARN` must be an external bootstrap/admin role that is not created by the `medrag-prod` CloudFormation stack
- `AWS_ROLE_ARN` is the stack-managed runtime deploy role output by CloudFormation
- never set `AWS_BOOTSTRAP_ROLE_ARN` equal to `AWS_ROLE_ARN`, because the destroy workflow deletes the stack-managed role

## 2. Set your shell variables

Run this on your machine and replace the placeholders:

```bash
export AWS_REGION="us-east-1"
export STACK_NAME="medrag-prod"
export PROJECT_SLUG="medrag-prod"
export GITHUB_OWNER="yashprogrammer"
export GITHUB_REPO="MedRAG"
export GH_REPO="${GITHUB_OWNER}/${GITHUB_REPO}"
export INSTANCE_TYPE="t3.large"
export SECRET_NAME="medrag/prod/app"
export OPENAI_API_KEY="replace-me"
export LLAMA_CLOUD_API_KEY="replace-me"
```

If you already know your target VPC and subnet:

```bash
export VPC_ID="vpc-xxxxxxxx"
export SUBNET_ID="subnet-xxxxxxxx"
```

If you need to discover them with AWS CLI, list them first:

```bash
aws ec2 describe-vpcs \
  --region "${AWS_REGION}" \
  --query 'Vpcs[].{Id:VpcId,Cidr:CidrBlock,Default:IsDefault,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table

aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --query 'Subnets[].{Id:SubnetId,Vpc:VpcId,AZ:AvailabilityZone,Cidr:CidrBlock,PublicIpOnLaunch:MapPublicIpOnLaunch,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

Pick a subnet where `PublicIpOnLaunch` is `true`, then export it:

```bash
export VPC_ID="vpc-xxxxxxxx"
export SUBNET_ID="subnet-xxxxxxxx"
```

## 3. Validate and deploy the CloudFormation stack with AWS CLI

Validate the template first:

```bash
aws cloudformation validate-template \
  --region "${AWS_REGION}" \
  --template-body file://infra/cloudformation/medrag-prod.yml >/dev/null
```

Deploy the production stack:

```bash
aws cloudformation deploy \
  --region "${AWS_REGION}" \
  --stack-name "${STACK_NAME}" \
  --template-file infra/cloudformation/medrag-prod.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ProjectSlug="${PROJECT_SLUG}" \
    VpcId="${VPC_ID}" \
    SubnetId="${SUBNET_ID}" \
    InstanceType="${INSTANCE_TYPE}" \
    GitHubOwner="${GITHUB_OWNER}" \
    GitHubRepository="${GITHUB_REPO}" \
    GitHubBranch="main" \
    SecretName="${SECRET_NAME}"
```

Enable termination protection:

```bash
aws cloudformation update-termination-protection \
  --region "${AWS_REGION}" \
  --stack-name "${STACK_NAME}" \
  --enable-termination-protection
```

## 4. Capture the stack outputs

Fetch and export the values we’ll need next:

```bash
STACK_OUTPUTS="$(aws cloudformation describe-stacks \
  --region "${AWS_REGION}" \
  --stack-name "${STACK_NAME}" \
  --query 'Stacks[0].Outputs' \
  --output json)"

export AWS_ROLE_ARN="$(printf '%s' "${STACK_OUTPUTS}" | jq -r '.[] | select(.OutputKey=="GitHubActionsRoleArn").OutputValue')"
export INSTANCE_ID="$(printf '%s' "${STACK_OUTPUTS}" | jq -r '.[] | select(.OutputKey=="InstanceId").OutputValue')"
export ELASTIC_IP="$(printf '%s' "${STACK_OUTPUTS}" | jq -r '.[] | select(.OutputKey=="ElasticIp").OutputValue')"
export ECR_REPOSITORY_URI="$(printf '%s' "${STACK_OUTPUTS}" | jq -r '.[] | select(.OutputKey=="EcrRepositoryUri").OutputValue')"
export DEPLOY_BUCKET_NAME="$(printf '%s' "${STACK_OUTPUTS}" | jq -r '.[] | select(.OutputKey=="DeployBucketName").OutputValue')"
export SECRET_ARN="$(printf '%s' "${STACK_OUTPUTS}" | jq -r '.[] | select(.OutputKey=="SecretArn").OutputValue')"

printf '%s\n' "${STACK_OUTPUTS}" | jq -r '.[] | "\(.OutputKey)=\(.OutputValue)"'
```

At this point, the stack has created the stack-managed runtime deploy role for app deployments. Keep using your existing external bootstrap/admin role for infrastructure and destroy operations.

## 5. Configure GitHub Actions with GitHub CLI

Authenticate GitHub CLI if needed:

```bash
gh auth login
gh auth status
```

### 5.1 Set repository variables

```bash
gh variable set AWS_REGION --repo "${GH_REPO}" --body "${AWS_REGION}"
gh variable set AWS_ROLE_ARN --repo "${GH_REPO}" --body "${AWS_ROLE_ARN}"
gh variable set AWS_BOOTSTRAP_ROLE_ARN --repo "${GH_REPO}" --body "arn:aws:iam::<account-id>:role/<external-bootstrap-role>"
gh variable set PROD_STACK_NAME --repo "${GH_REPO}" --body "${STACK_NAME}"
gh variable set PROD_VPC_ID --repo "${GH_REPO}" --body "${VPC_ID}"
gh variable set PROD_SUBNET_ID --repo "${GH_REPO}" --body "${SUBNET_ID}"
gh variable set PROD_INSTANCE_TYPE --repo "${GH_REPO}" --body "${INSTANCE_TYPE}"
gh variable set PROD_SECRET_NAME --repo "${GH_REPO}" --body "${SECRET_NAME}"
```

Set `AWS_BOOTSTRAP_ROLE_ARN` to a stable role outside the `medrag-prod` stack. Good options are:

- a manually managed GitHub OIDC bootstrap role in the same AWS account
- a long-lived admin/bootstrap role managed in a separate infrastructure stack
- skip the GitHub `Destroy Production` workflow entirely and use your local AWS CLI admin credentials with `scripts/destroy-prod.sh`

### 5.2 Set GitHub repository secrets for CI evals

```bash
printf '%s' "${OPENAI_API_KEY}" | gh secret set OPENAI_API_KEY --repo "${GH_REPO}"
printf '%s' "${LLAMA_CLOUD_API_KEY}" | gh secret set LLAMA_CLOUD_API_KEY --repo "${GH_REPO}"
```

These are used by the `Evaluation` workflow before deployment.

## 6. Put the runtime secrets into AWS Secrets Manager

Update the stack-created secret with real values:

```bash
aws secretsmanager put-secret-value \
  --region "${AWS_REGION}" \
  --secret-id "${SECRET_NAME}" \
  --secret-string "$(jq -nc \
    --arg openai "${OPENAI_API_KEY}" \
    --arg llama "${LLAMA_CLOUD_API_KEY}" \
    '{OPENAI_API_KEY: $openai, LLAMA_CLOUD_API_KEY: $llama}')"
```

Verify the secret exists:

```bash
aws secretsmanager describe-secret \
  --region "${AWS_REGION}" \
  --secret-id "${SECRET_NAME}" \
  --query '{Name:Name,ARN:ARN}' \
  --output table
```

## 7. Trigger the first deploy from the CLI

The deploy flow is:

1. push to `main`
2. `Evaluation` runs
3. if `Evaluation` succeeds, `Deploy Production` runs automatically

If you just want to trigger a deploy without changing code:

```bash
git checkout main
git pull origin main
git commit --allow-empty -m "Trigger production deploy"
git push origin main
```

## 8. Watch the GitHub Actions runs from the CLI

Watch the `Evaluation` workflow first:

```bash
gh run list --repo "${GH_REPO}" --workflow eval.yml --limit 5
```

If the newest run is the one you just triggered, watch it:

```bash
EVAL_RUN_ID="$(gh run list \
  --repo "${GH_REPO}" \
  --workflow eval.yml \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId')"

gh run watch "${EVAL_RUN_ID}" --repo "${GH_REPO}"
```

Then watch the deploy run:

```bash
DEPLOY_RUN_ID=""
until [ -n "${DEPLOY_RUN_ID}" ] && [ "${DEPLOY_RUN_ID}" != "null" ]; do
  DEPLOY_RUN_ID="$(gh run list \
    --repo "${GH_REPO}" \
    --workflow deploy-prod.yml \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId')"
  sleep 10
done

gh run watch "${DEPLOY_RUN_ID}" --repo "${GH_REPO}"
```

If either workflow fails, inspect its logs:

```bash
gh run view "${EVAL_RUN_ID}" --repo "${GH_REPO}" --log
gh run view "${DEPLOY_RUN_ID}" --repo "${GH_REPO}" --log
```

## 9. Test the live deployment from the CLI

### 9.1 Check the public endpoints

```bash
curl -I "http://${ELASTIC_IP}/"
curl "http://${ELASTIC_IP}/healthz"
```

Expected result:

- `http://${ELASTIC_IP}/` returns the Streamlit app HTML
- `http://${ELASTIC_IP}/healthz` returns the MedRAG health payload

### 9.2 Run a quick remote check through SSM

Send a one-off command to the EC2 instance:

```bash
COMMAND_ID="$(aws ssm send-command \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=[
    "curl -fsS http://127.0.0.1:8000/health",
    "sudo docker compose --env-file /opt/medrag/runtime/app.env -f /opt/medrag/app/current/docker-compose.prod.yml ps"
  ]' \
  --query 'Command.CommandId' \
  --output text)"

aws ssm get-command-invocation \
  --region "${AWS_REGION}" \
  --command-id "${COMMAND_ID}" \
  --instance-id "${INSTANCE_ID}" \
  --output json
```

### 9.3 Open an interactive SSM session if needed

```bash
aws ssm start-session \
  --region "${AWS_REGION}" \
  --target "${INSTANCE_ID}"
```

Once you are on the instance:

```bash
cd /opt/medrag/app/current
sudo docker compose --env-file /opt/medrag/runtime/app.env -f docker-compose.prod.yml ps
sudo docker compose --env-file /opt/medrag/runtime/app.env -f docker-compose.prod.yml logs --tail=200
```

## 10. Normal redeploy flow

After the first deployment, the normal flow is simple:

1. merge to `main`
2. `Evaluation` runs
3. `Deploy Production` runs automatically if evaluation is green

You can observe those runs with:

```bash
gh run list --repo "${GH_REPO}" --workflow eval.yml --limit 5
gh run list --repo "${GH_REPO}" --workflow deploy-prod.yml --limit 5
```

## 11. Optional: run the infrastructure workflow from the CLI

If you want future infrastructure changes to go through GitHub Actions instead of local AWS CLI:

```bash
gh workflow run infrastructure.yml --repo "${GH_REPO}"
```

Then watch it:

```bash
INFRA_RUN_ID="$(gh run list \
  --repo "${GH_REPO}" \
  --workflow infrastructure.yml \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId')"

gh run watch "${INFRA_RUN_ID}" --repo "${GH_REPO}"
```

## 12. Destroy everything completely

### 12.1 Destroy through the GitHub workflow from the CLI

Before running this, make sure the repository variable `AWS_BOOTSTRAP_ROLE_ARN` points to an external bootstrap/admin role and does not equal `AWS_ROLE_ARN`.

Trigger the destroy workflow:

```bash
gh workflow run destroy-prod.yml \
  --repo "${GH_REPO}" \
  -f confirmation=DESTROY_MEDRAG_PROD
```

Watch it:

```bash
DESTROY_RUN_ID="$(gh run list \
  --repo "${GH_REPO}" \
  --workflow destroy-prod.yml \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId')"

gh run watch "${DESTROY_RUN_ID}" --repo "${GH_REPO}"
```

### 12.2 Or destroy locally with the repo script

If you prefer to destroy directly from your machine:

```bash
bash scripts/destroy-prod.sh \
  --stack-name "${STACK_NAME}" \
  --region "${AWS_REGION}" \
  --confirm DESTROY_MEDRAG_PROD
```

### 12.3 Verify the stack is gone

These should fail or return empty after a full destroy:

```bash
aws cloudformation describe-stacks \
  --region "${AWS_REGION}" \
  --stack-name "${STACK_NAME}"

aws ecr describe-repositories \
  --region "${AWS_REGION}" \
  --repository-names "${PROJECT_SLUG}-app"

aws secretsmanager describe-secret \
  --region "${AWS_REGION}" \
  --secret-id "${SECRET_NAME}"
```

You can also verify that the Elastic IP no longer exists:

```bash
aws ec2 describe-addresses \
  --region "${AWS_REGION}" \
  --public-ips "${ELASTIC_IP}"
```

## 13. Troubleshooting

### CloudFormation deploy fails

Check:

- `VPC_ID` and `SUBNET_ID` are valid
- your local AWS credentials can create IAM, EC2, ECR, S3, Secrets Manager, and CloudFormation resources

### Evaluation succeeds locally but fails in GitHub Actions

Check:

- `OPENAI_API_KEY` and `LLAMA_CLOUD_API_KEY` are set as GitHub repository secrets
- the repo secrets are correct and not expired

### Deploy workflow fails

Check:

- `AWS_ROLE_ARN` repository variable is set from the stack output `GitHubActionsRoleArn`
- the Secrets Manager secret contains real values, not placeholders
- the EC2 instance is visible to SSM

### UI opens but the app is not ready

This usually means:

- the indexer is still running
- or indexing failed on the instance

Inspect remotely:

```bash
aws ssm start-session \
  --region "${AWS_REGION}" \
  --target "${INSTANCE_ID}"
```

Then:

```bash
sudo docker compose --env-file /opt/medrag/runtime/app.env -f /opt/medrag/app/current/docker-compose.prod.yml logs indexer api qdrant
```

## 14. The shortest working path

If you just want the minimum CLI sequence:

1. export the variables in section 2
2. run the CloudFormation deploy command in section 3
3. capture the outputs in section 4
4. set GitHub variables and secrets in sections 5 and 6
5. push to `main`
6. watch `Evaluation` and `Deploy Production`
7. test `http://${ELASTIC_IP}/` and `http://${ELASTIC_IP}/healthz`
8. destroy with `gh workflow run destroy-prod.yml -f confirmation=DESTROY_MEDRAG_PROD`

That is the full CLI-first lifecycle for this setup.
