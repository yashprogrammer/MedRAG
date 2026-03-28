#!/usr/bin/env bash
set -euo pipefail

STACK_NAME=""
AWS_REGION=""
CONFIRM_VALUE=""
EXPECTED_CONFIRMATION="DESTROY_MEDRAG_PROD"

usage() {
  cat <<'EOF'
usage: destroy-prod.sh --stack-name <stack-name> --region <aws-region> --confirm DESTROY_MEDRAG_PROD
EOF
}

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    --confirm)
      CONFIRM_VALUE="$2"
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${STACK_NAME}" || -z "${AWS_REGION}" || -z "${CONFIRM_VALUE}" ]]; then
  usage
  exit 1
fi

if [[ "${CONFIRM_VALUE}" != "${EXPECTED_CONFIRMATION}" ]]; then
  printf 'Refusing to destroy stack without the exact confirmation string.\n' >&2
  exit 1
fi

require_command aws
require_command jq

STACK_JSON="$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" --output json)"

get_output() {
  local key="$1"
  printf '%s' "${STACK_JSON}" | jq -r --arg key "${key}" '.Stacks[0].Outputs[] | select(.OutputKey == $key) | .OutputValue'
}

INSTANCE_ID="$(get_output InstanceId)"
DEPLOY_BUCKET_NAME="$(get_output DeployBucketName)"
ECR_REPOSITORY_NAME="$(get_output EcrRepositoryName)"
SECRET_ARN="$(get_output SecretArn)"
ELASTIC_IP="$(get_output ElasticIp)"
SECURITY_GROUP_ID="$(get_output SecurityGroupId)"
STACK_GITHUB_ROLE_ARN="$(get_output GitHubActionsRoleArn)"

CALLER_ARN="$(aws sts get-caller-identity --region "${AWS_REGION}" --query Arn --output text)"
STACK_GITHUB_ROLE_NAME="${STACK_GITHUB_ROLE_ARN##*/}"

if [[ -n "${STACK_GITHUB_ROLE_ARN}" && "${STACK_GITHUB_ROLE_ARN}" != "null" ]]; then
  if [[ "${CALLER_ARN}" == "${STACK_GITHUB_ROLE_ARN}" || "${CALLER_ARN}" == arn:aws:sts::*:assumed-role/${STACK_GITHUB_ROLE_NAME}/* ]]; then
    printf 'Refusing to destroy stack %s while authenticated as the stack-managed GitHub role.\n' "${STACK_NAME}" >&2
    printf 'Use an external bootstrap/admin role for destroy operations and keep AWS_BOOTSTRAP_ROLE_ARN separate from AWS_ROLE_ARN.\n' >&2
    exit 1
  fi
fi

send_teardown_command() {
  local commands_json
  commands_json="$(jq -nc '[
    "set -euo pipefail",
    "if [ -f /opt/medrag/app/current/scripts/teardown-app.sh ]; then sudo bash /opt/medrag/app/current/scripts/teardown-app.sh; else sudo rm -rf /opt/medrag/app /opt/medrag/runtime /opt/medrag/data/qdrant /opt/medrag/data/medrag; fi"
  ]')"

  aws ssm send-command \
    --instance-ids "${INSTANCE_ID}" \
    --document-name AWS-RunShellScript \
    --parameters "commands=${commands_json}" \
    --comment "Teardown MedRAG app before deleting ${STACK_NAME}" \
    --region "${AWS_REGION}" \
    --query 'Command.CommandId' \
    --output text
}

wait_for_command() {
  local command_id="$1"
  local status
  while true; do
    status="$(aws ssm get-command-invocation \
      --command-id "${command_id}" \
      --instance-id "${INSTANCE_ID}" \
      --region "${AWS_REGION}" \
      --query Status \
      --output text 2>/dev/null || true)"
    case "${status}" in
      Success)
        return 0
        ;;
      Cancelled|Failed|TimedOut|Cancelling)
        return 1
        ;;
      *)
        sleep 5
        ;;
    esac
  done
}

empty_versioned_bucket() {
  local bucket="$1"
  local payload
  local count

  if [[ -z "${bucket}" || "${bucket}" == "null" ]]; then
    return 0
  fi

  log "Removing all objects from ${bucket}"
  aws s3 rm "s3://${bucket}" --recursive --region "${AWS_REGION}" || true

  while true; do
    payload="$(aws s3api list-object-versions --bucket "${bucket}" --region "${AWS_REGION}" --output json)"
    count="$(printf '%s' "${payload}" | jq '[.Versions[]?, .DeleteMarkers[]?] | length')"
    if [[ "${count}" == "0" ]]; then
      break
    fi
    aws s3api delete-objects \
      --bucket "${bucket}" \
      --region "${AWS_REGION}" \
      --delete "$(printf '%s' "${payload}" | jq '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key, VersionId})), Quiet: true}')" >/dev/null
  done
}

verify_absent() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'Expected %s to be absent, but it is still present.\n' "${description}" >&2
    return 1
  fi
}

if [[ -n "${INSTANCE_ID}" && "${INSTANCE_ID}" != "null" ]]; then
  log "Stopping application on ${INSTANCE_ID}"
  if command_id="$(send_teardown_command)"; then
    wait_for_command "${command_id}" || true
  fi
fi

empty_versioned_bucket "${DEPLOY_BUCKET_NAME}"

log "Disabling stack termination protection"
aws cloudformation update-termination-protection \
  --no-enable-termination-protection \
  --stack-name "${STACK_NAME}" \
  --region "${AWS_REGION}" || true

log "Deleting CloudFormation stack ${STACK_NAME}"
aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${AWS_REGION}"

if ! aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" --region "${AWS_REGION}"; then
  log "Stack deletion did not complete cleanly; forcing leftover resource cleanup"
  aws ecr delete-repository --repository-name "${ECR_REPOSITORY_NAME}" --force --region "${AWS_REGION}" || true
  aws secretsmanager delete-secret --secret-id "${SECRET_ARN}" --force-delete-without-recovery --region "${AWS_REGION}" || true
  aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" --region "${AWS_REGION}"
fi

log "Verifying resources are gone"
verify_absent "stack" aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}"
verify_absent "ECR repository" aws ecr describe-repositories --repository-names "${ECR_REPOSITORY_NAME}" --region "${AWS_REGION}"
verify_absent "secret" aws secretsmanager describe-secret --secret-id "${SECRET_ARN}" --region "${AWS_REGION}"
verify_absent "Elastic IP" aws ec2 describe-addresses --public-ips "${ELASTIC_IP}" --region "${AWS_REGION}"
verify_absent "security group" aws ec2 describe-security-groups --group-ids "${SECURITY_GROUP_ID}" --region "${AWS_REGION}"

log "Full destroy completed for ${STACK_NAME}"
