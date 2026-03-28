# RAG Toolkit

This repository starts with Project 1: MedRAG. It builds a single RAG pipeline with a MedRAG-specific ingestion layer and a shared retrieval and serving core that can later be reused for FinRAG.

## What exists

- `src/core/`: shared configuration, indexing, retrieval, generation, and service wiring
- `src/projects/medrag/`: MedRAG config plus LlamaParse and PubMed ingestion
- `src/api/`: FastAPI query surface
- `src/ui/`: Streamlit client for the API
- `eval/medrag/`: MedRAG golden dataset and evaluation test scaffold

## Quick start

1. Copy `.env.example` to `.env` and fill in `OPENAI_API_KEY` and `LLAMA_CLOUD_API_KEY`.
2. Put guideline PDFs under `src/projects/medrag/data/guidelines/`.
3. Start Qdrant with `make qdrant-up`.
4. Install dependencies with `uv sync --extra dev` or `make install`.
5. Build the index with `make index-medrag`.
6. Run the API with `make run-medrag`.
7. Run the UI with `make run-ui`.

## Important behavior

- Ingestion and indexing are explicit commands.
- The API only serves a previously indexed collection.
- PubMed ingestion is included in the index build and can be adjusted in `src/projects/medrag/ingestor.py`.
- Embeddings use local `BAAI/bge-small-en-v1.5` through LlamaIndex's FastEmbed integration.
- The default embedding size is 384 dimensions, so fresh indexes use a different Qdrant collection name from the old Gemini-backed setup.

## Full Docker Compose stack

If you want Docker Compose to run everything, use:

```bash
docker compose up --build
```

Or:

```bash
make compose-up
```

This starts:

- `qdrant`: vector database
- `indexer`: waits for Qdrant, then builds the MedRAG collection if it does not already exist
- `api`: starts immediately on port `8000` and reports collection readiness through `/health`
- `ui`: starts Streamlit on port `8501`

Before running the stack:

1. Add your API keys to `.env`.
2. Put your PDFs in `src/projects/medrag/data/guidelines/`.

Then open:

- `http://localhost:8000/docs`
- `http://localhost:8501`

Notes:

- The Streamlit dashboard now includes an `Uploaded Sources` tab for listing, uploading, deleting, and reindexing local PDF sources.
- On the first boot, the UI may show that the collection is not ready while the `indexer` is still parsing PDFs and PubMed content. That is expected.
- This repo now defaults to the `medrag_collection_bge_small` collection. If you have an older Gemini-backed collection, it will not be reused.
- Qdrant is no longer published to the host by default, so it will not conflict with another local service on port `6333`.
- The first local embedding run may download the FastEmbed model into the container or local cache before indexing starts.
- After switching from Gemini to BGE, do a fresh reindex so the new 384-d collection is built from scratch.
- If you want the Qdrant dashboard on your host machine, run:

```bash
docker compose -f docker-compose.yml -f docker-compose.debug.yml up --build
```

To stop the stack:

```bash
docker compose down
```

## AWS production deployment

This repo now includes a production deployment path for a single EC2 instance on AWS:

- CloudFormation owns the infrastructure in [infra/cloudformation/medrag-prod.yml](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/infra/cloudformation/medrag-prod.yml)
- GitHub Actions builds and deploys the app through:
  - [infrastructure.yml](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/.github/workflows/infrastructure.yml)
  - [deploy-prod.yml](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/.github/workflows/deploy-prod.yml)
  - [destroy-prod.yml](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/.github/workflows/destroy-prod.yml)
- Secrets live in AWS Secrets Manager
- The production runtime uses [docker-compose.prod.yml](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/docker-compose.prod.yml)

For the full CLI-first operator walkthrough, use [docs/aws-ec2-cicd-runbook.md](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/docs/aws-ec2-cicd-runbook.md).

### What gets created

- one EC2 instance running Amazon Linux 2023
- one Elastic IP
- one security group exposing only port `80`
- one ECR repository for the shared MedRAG image
- one versioned S3 bucket for deployment bundles
- one Secrets Manager secret for `OPENAI_API_KEY` and `LLAMA_CLOUD_API_KEY`
- one GitHub Actions OIDC role for deploy/destroy workflows

### Required GitHub repository variables

For the infrastructure workflow:

- `AWS_REGION`
- `AWS_BOOTSTRAP_ROLE_ARN`
- `PROD_STACK_NAME`
- `PROD_VPC_ID`
- `PROD_SUBNET_ID`
- `PROD_INSTANCE_TYPE`
- `PROD_SECRET_NAME`
- `EXISTING_GITHUB_OIDC_PROVIDER_ARN` (optional, leave empty to let the stack create the provider)

For the deploy and destroy workflows:

- `AWS_REGION`
- `AWS_ROLE_ARN`
- `PROD_STACK_NAME`

The split is intentional:

- `AWS_BOOTSTRAP_ROLE_ARN` is an existing admin/bootstrap role used only to create or update the CloudFormation stack
- `AWS_ROLE_ARN` should be set to the stack output `GitHubActionsRoleArn` after the first infrastructure deployment

### First-time setup

1. Review [infra/cloudformation/medrag-prod.parameters.example.json](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/infra/cloudformation/medrag-prod.parameters.example.json) and create the repo variables listed above.
2. Run the `Infrastructure` GitHub Actions workflow manually.
3. Copy the stack output `GitHubActionsRoleArn` into the repository variable `AWS_ROLE_ARN`.
4. Update the created Secrets Manager secret with real values for:
   - `OPENAI_API_KEY`
   - `LLAMA_CLOUD_API_KEY`
5. Push to `main` after the `Evaluation` workflow is green. That triggers the production deploy workflow automatically.

### Runtime behavior

- The instance bootstrap happens through EC2 user data. A matching helper script exists at [scripts/bootstrap-ec2.sh](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/scripts/bootstrap-ec2.sh) for reference or manual recovery.
- Production env defaults live in [deploy/app.env.prod](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/deploy/app.env.prod).
- The deploy bundle is built with [scripts/package-deploy-bundle.sh](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/scripts/package-deploy-bundle.sh).
- Remote rollout and rollback happen through [scripts/deploy-prod.sh](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/scripts/deploy-prod.sh).
- Full app cleanup on the instance uses [scripts/teardown-app.sh](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/scripts/teardown-app.sh).

The production instance keeps these paths persistent:

- `/opt/medrag/data/qdrant`
- `/opt/medrag/data/medrag`
- `/opt/medrag/runtime`

### Production deploy flow

When `deploy-prod.yml` runs on a successful `main` build:

1. the app image is built once and pushed to ECR
2. the production bundle is uploaded to S3
3. SSM Run Command executes the remote deploy script on the EC2 instance
4. the script pulls the image, renders `/opt/medrag/runtime/app.env`, runs the one-shot indexer, and starts `qdrant`, `api`, `ui`, and `nginx`
5. the workflow waits for `http://localhost:8000/health` on the instance and `http://<elastic-ip>/` publicly

### Production destroy flow

To completely wipe the production environment:

1. run the `Destroy Production` workflow manually
2. type `DESTROY_MEDRAG_PROD` as confirmation

This uses [scripts/destroy-prod.sh](/Users/yashpatil/Developer/AI/Evolvue/MedRAG/scripts/destroy-prod.sh) to:

- stop and remove the app stack on the instance
- delete uploaded PDFs, Qdrant data, runtime env, and local eval artifacts
- empty the deployment S3 bucket, including versioned objects
- delete the ECR repository contents and repository
- delete the Secrets Manager secret
- delete the CloudFormation stack and verify the remaining resources are gone

### Notes

- v1 exposes the app on the EC2 Elastic IP over plain HTTP only.
- FastAPI is kept private behind the reverse proxy; only the Streamlit UI is internet-facing.
- No inbound SSH is required. Use AWS Systems Manager Session Manager or Run Command instead.
