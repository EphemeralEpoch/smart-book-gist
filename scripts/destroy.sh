#!/usr/bin/env bash
# scripts/destroy.sh
# Full teardown of resources created by bootstrap_full.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Load .env
if [ -f .env ]; then
  set -a; source .env; set +a
fi

# Color-coded logging
info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
fatal(){ printf "\033[1;31m[FATAL]\033[0m %s\n" "$*"; exit 1; }

# Required config
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID must be set in .env}"
: "${GCP_REGION:=us-central1}"
: "${SERVICE_NAME:=smart-book-gist}"
: "${ARTIFACT_REPO:=gist-repo}"

RUNTIME_SA="smart-book-gist-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
BUILDER_SA="cbuilder@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
PROJECT="${GCP_PROJECT_ID}"
REGION="${GCP_REGION}"
REPO="${ARTIFACT_REPO}"
PROJECT_NUM=$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')

# Helper: remove IAM binding if it exists
remove_binding_if_exists() {
  local member="$1"
  local role="$2"
  if gcloud projects get-iam-policy "${PROJECT}" --format=json \
      | jq -e ".bindings[]? | select(.role==\"${role}\") | .members[]? | select(.==\"${member}\")" >/dev/null; then
    info "Removing binding: ${member} -> ${role}"
    gcloud projects remove-iam-policy-binding "${PROJECT}" \
      --member="${member}" --role="${role}" --quiet
  else
    info "No binding found for ${member} on ${role}, skipping."
  fi
}

info "Destroying Cloud Run service (if exists)..."
if gcloud run services describe "${SERVICE_NAME}" --region="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud run services delete "${SERVICE_NAME}" --region="${REGION}" --project="${PROJECT}" --quiet
  info "Deleted Cloud Run service: ${SERVICE_NAME}"
else
  info "Cloud Run service ${SERVICE_NAME} does not exist, skipping."
fi

info "Deleting artifact images from repo..."
gcloud artifacts docker images list "${REGION}-docker.pkg.dev/${PROJECT}/${REPO}" --project="${PROJECT}" --format="value(name)" \
  | xargs -r -n1 gcloud artifacts docker images delete --quiet --project="${PROJECT}" || true

info "Deleting artifact repo (if exists)..."
if gcloud artifacts repositories describe "${REPO}" --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud artifacts repositories delete "${REPO}" --location="${REGION}" --project="${PROJECT}" --quiet
  info "Deleted Artifact Registry repo: ${REPO}"
else
  info "Artifact Registry repo ${REPO} does not exist, skipping."
fi

info "Deleting secret (if exists)..."
if gcloud secrets describe groq-api-key --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud secrets delete groq-api-key --project="${PROJECT}" --quiet
  info "Deleted secret: groq-api-key"
else
  info "Secret groq-api-key does not exist, skipping."
fi

info "Removing project-level IAM bindings added by bootstrap (best-effort)..."
remove_binding_if_exists "serviceAccount:${BUILDER_SA}" "roles/cloudbuild.builds.builder"
remove_binding_if_exists "serviceAccount:${BUILDER_SA}" "roles/logging.logWriter"
remove_binding_if_exists "serviceAccount:${BUILDER_SA}" "roles/artifactregistry.writer"
remove_binding_if_exists "serviceAccount:${RUNTIME_SA}" "roles/artifactregistry.reader"
remove_binding_if_exists "serviceAccount:${RUNTIME_SA}" "roles/run.invoker"
remove_binding_if_exists "serviceAccount:${RUNTIME_SA}" "roles/secretmanager.secretAccessor"

info "Deleting runtime service account (if exists)..."
if gcloud iam service-accounts describe "${RUNTIME_SA}" --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud iam service-accounts delete "${RUNTIME_SA}" --project="${PROJECT}" --quiet
  info "Deleted service account: ${RUNTIME_SA}"
else
  info "Service account ${RUNTIME_SA} does not exist, skipping."
fi

info "Deleting builder service account (if exists)..."
if gcloud iam service-accounts describe "${BUILDER_SA}" --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud iam service-accounts delete "${BUILDER_SA}" --project="${PROJECT}" --quiet
  info "Deleted service account: ${BUILDER_SA}"
else
  info "Service account ${BUILDER_SA} does not exist, skipping."
fi

info "Full resource teardown complete."
