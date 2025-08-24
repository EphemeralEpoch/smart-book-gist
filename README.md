# groq-python-app

Minimal Python client for the Groq OpenAI-compatible chat endpoint. Supports **local execution** and deployment to **Google Cloud Run**.

---

## Features

- Send prompts to Groq API and receive structured JSON responses.
- Run locally with environment variables or via Cloud Run with secret injection.
- Supports file-based prompts and customizable output paths.
- Configurable model parameters (`model`, `temperature`, `max_tokens`).

---

## Requirements

- Python 3.10+ (3.11 recommended)
- Google Cloud SDK (`gcloud`) if deploying or invoking on Cloud Run
- `pip install -r requirements.txt`
- Optional: Docker if building images locally

---

## Setup

1. Copy environment template:

cp .env.example .env

2. Fill in your Groq API key:

GROQ_API_KEY=<your_api_key_here>

Security: Never commit .env to source control. Rotate API keys if exposed.

3. Install Python dependencies:

pip install -r requirements.txt

## Local Usage
Run the client locally:
Default prompt:
python src/main.py

Custom prompt:
python src/main.py --prompt "Summarize the benefits of short-run model inference."

File-based input/output:
python src/main.py --file ./prompt.txt --out outputs/result.json

Additional flags:
--model
--temperature
--max-tokens

Outputs are saved to outputs/groq-response-<timestamp>.json by default.

## Cloud Run Usage

Deploy

1. Build and deploy via provided scripts:
./scripts/bootstrap_full.sh   # Sets up project, secrets, service accounts
./scripts/deploy.sh           # Deploys Cloud Run service


2. Check service URL:
gcloud run services describe smart-book-gist --region=us-central1 --format="value(status.url)"

3. Invoke
With token-based authentication (recommended in org-restricted environments):
./scripts/invoke.sh <SERVICE_URL> <SERVICE_ACCOUNT_EMAIL> "<your prompt here>"

Example:
./scripts/invoke.sh https://smart-book-gist-<project>.run.app smart-book-gist-sa@sandbox-ahmed.iam.gserviceaccount.com "Summarize Hunger in 3 bullets"

## Teardown / Cleanup

./scripts/destroy.sh

Deletes Cloud Run service, artifact repo/images, secrets, and service accounts.
Idempotent and safe to run multiple times.