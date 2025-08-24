#!/usr/bin/env bash
# scripts/bootstrap_full.sh
# Idempotent, repeatable bootstrap:
# - enables required APIs
# - creates Artifact Registry repo (if missing)
# - creates a dedicated builder SA (cbuilder) and runtime SA
# - grants repo-level/project-level IAM as needed (automated fallback)
# - grants iam.serviceAccountUser so Cloud Build can impersonate builder SA
# - grants active user permission to impersonate runtime SA
# - grants runtime SA Cloud Run invoker role (best-effort)
# - creates secret and adds GROQ_API_KEY
# - ensures runtime SA has secret access (roles/secretmanager.secretAccessor)
# - waits for IAM visibility (accepts repo OR project-level grants)
# - builds & pushes image using the dedicated builder SA via cloudbuild.yaml
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
fatal(){ printf "\033[1;31m[FATAL]\033[0m %s\n" "$*"; exit 1; }

# load .env
if [ ! -f .env ]; then
  fatal ".env not found in project root. Create one based on .env.example"
fi
set -a; source .env; set +a

: "${GCP_PROJECT_ID:?must be set in .env (GCP_PROJECT_ID)}"
: "${GCP_REGION:=us-central1}"
: "${SERVICE_NAME:=smart-book-gist}"
: "${ARTIFACT_REPO:=gist-repo}"

PROJECT="${GCP_PROJECT_ID}"
REGION="${GCP_REGION}"
REPO="${ARTIFACT_REPO}"
SERVICE="${SERVICE_NAME}"
PROJECT_NUM="$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')"

BUILDER_SA_NAME="cbuilder"
BUILDER_SA_EMAIL="${BUILDER_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
BUILDER_SA_RESOURCE="projects/${PROJECT}/serviceAccounts/${BUILDER_SA_EMAIL}"

RUNTIME_SA_NAME="${SERVICE}-sa"
RUNTIME_SA_EMAIL="${RUNTIME_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

COMPUTE_SA="${PROJECT_NUM}-compute@developer.gserviceaccount.com"
CLOUDBUILD_SA="${PROJECT_NUM}@cloudbuild.gserviceaccount.com"
CLOUDBUILD_AGENT_SA="service-${PROJECT_NUM}@gcp-sa-cloudbuild.iam.gserviceaccount.com"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/${SERVICE}:latest"

info "bootstrap: project=${PROJECT} region=${REGION} repo=${REPO} service=${SERVICE} image=${IMAGE}"

# quick permission probe
if ! gcloud projects get-iam-policy "${PROJECT}" >/dev/null 2>&1; then
  fatal "Cannot read project IAM policy. Run this script as a user with permission to read project IAM (Owner/IAM Admin)."
fi

info "Enabling required APIs..."
gcloud services enable --project="${PROJECT}" \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com >/dev/null

# create artifact repo if missing
if ! gcloud artifacts repositories describe "${REPO}" --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
  info "Creating Artifact Registry repo ${REPO}..."
  gcloud artifacts repositories create "${REPO}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="Docker repo for ${SERVICE}" \
    --project="${PROJECT}"
else
  info "Artifact repo ${REPO} exists."
fi

# create builder SA if missing
if ! gcloud iam service-accounts describe "${BUILDER_SA_EMAIL}" --project="${PROJECT}" >/dev/null 2>&1; then
  info "Creating builder service account ${BUILDER_SA_EMAIL}..."
  gcloud iam service-accounts create "${BUILDER_SA_NAME}" \
    --display-name="Cloud Build custom builder" \
    --project="${PROJECT}"
  # wait for SA to be visible
  info "Waiting for builder service account to be fully created..."
  for i in {1..12}; do
    if gcloud iam service-accounts describe "${BUILDER_SA_EMAIL}" --project="${PROJECT}" >/dev/null 2>&1; then
      info "Builder SA visible."
      break
    fi
    sleep 2
  done
else
  info "Builder service account ${BUILDER_SA_EMAIL} exists."
fi

# helper to add project-level binding and confirm it's present (retrying on eventual consistency)
add_project_binding_with_retry(){
  local member="$1" role="$2" attempt=1 max=6
  while [ $attempt -le $max ]; do
    if gcloud projects add-iam-policy-binding "${PROJECT}" --member="${member}" --role="${role}" >/dev/null 2>&1; then
      # confirm presence
      if gcloud projects get-iam-policy "${PROJECT}" --format="yaml" 2>/dev/null | grep -q "${member}"; then
        info "Confirmed project-level binding: ${member} -> ${role}"
        return 0
      fi
    fi
    warn "Could not add/confirm project-level binding ${member} -> ${role} (attempt ${attempt}/${max}). Retrying..."
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
  warn "Giving up adding project-level binding ${member} -> ${role} after ${max} attempts."
  return 1
}

# grant builder project-level roles required to run builds
info "Granting project-level roles to builder SA (cloudbuild.builds.builder, logging.logWriter, storage.admin)..."
add_project_binding_with_retry "serviceAccount:${BUILDER_SA_EMAIL}" "roles/cloudbuild.builds.builder" || warn "grant cloudbuild.builds.builder may have insufficient perms or already applied"
add_project_binding_with_retry "serviceAccount:${BUILDER_SA_EMAIL}" "roles/logging.logWriter" || warn "grant logging.logWriter may have insufficient perms or already applied"
add_project_binding_with_retry "serviceAccount:${BUILDER_SA_EMAIL}" "roles/storage.admin" || warn "grant storage.admin may have insufficient perms or already applied"

# create runtime SA if missing
if ! gcloud iam service-accounts describe "${RUNTIME_SA_EMAIL}" --project="${PROJECT}" >/dev/null 2>&1; then
  info "Creating runtime service account ${RUNTIME_SA_EMAIL}..."
  gcloud iam service-accounts create "${RUNTIME_SA_NAME}" --display-name="Cloud Run runtime SA for ${SERVICE}" --project="${PROJECT}"
  # wait for SA to be visible
  info "Waiting for runtime service account to be fully created..."
  for i in {1..12}; do
    if gcloud iam service-accounts describe "${RUNTIME_SA_EMAIL}" --project="${PROJECT}" >/dev/null 2>&1; then
      info "Runtime SA visible."
      break
    fi
    sleep 2
  done
else
  info "Runtime SA ${RUNTIME_SA_EMAIL} exists."
fi

# grant active user impersonation rights on runtime SA
info "Granting active user permission to impersonate runtime SA..."
if ! gcloud iam service-accounts add-iam-policy-binding "${RUNTIME_SA_EMAIL}" \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="${PROJECT}" >/dev/null 2>&1; then
  warn "grant iam.serviceAccountTokenCreator may have insufficient perms or already applied"
else
  info "Granted impersonation rights on runtime SA to active user."
fi

# grant runtime SA Cloud Run invoker role (best-effort)
info "Granting Cloud Run invoker role to runtime SA (best-effort)..."
if ! gcloud run services add-iam-policy-binding "${SERVICE}" \
     --member="serviceAccount:${RUNTIME_SA_EMAIL}" \
     --role="roles/run.invoker" \
     --region="${REGION}" \
     --project="${PROJECT}" >/dev/null 2>&1; then
  warn "Failed to bind roles/run.invoker to runtime SA (may not exist yet or insufficient perms). This will be retried later if needed."
else
  info "Runtime SA can invoke Cloud Run service (service-level binding applied)."
fi

# helper function for repo-level binding
attempt_repo_binding(){
  local member="$1"
  local role="$2"
  if gcloud artifacts repositories get-iam-policy "${REPO}" --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
    if gcloud artifacts repositories add-iam-policy-binding "${REPO}" \
         --location="${REGION}" \
         --member="${member}" \
         --role="${role}" \
         --project="${PROJECT}" >/dev/null 2>&1; then
      info "Repo-level binding added: ${member} -> ${role}"
      return 0
    else
      warn "Repo-level binding failed for ${member} -> ${role}"
      return 1
    fi
  else
    warn "Unable to read repo IAM policy; skipping repo-level binding attempt for ${member}"
    return 1
  fi
}

# Add artifactregistry roles (builder, compute, runtime)
info "Ensure builder SA has artifactregistry.writer (repo-level preferred, fallback to project-level)..."
if ! attempt_repo_binding "serviceAccount:${BUILDER_SA_EMAIL}" "roles/artifactregistry.writer"; then
  add_project_binding_with_retry "serviceAccount:${BUILDER_SA_EMAIL}" "roles/artifactregistry.writer" || warn "project-level fallback grant failed"
fi

info "Ensure compute SA has artifactregistry.writer (repo-level preferred, fallback to project-level)..."
if ! attempt_repo_binding "serviceAccount:${COMPUTE_SA}" "roles/artifactregistry.writer"; then
  add_project_binding_with_retry "serviceAccount:${COMPUTE_SA}" "roles/artifactregistry.writer" || warn "project-level fallback grant failed"
fi

info "Ensure runtime SA has artifactregistry.reader (repo-level preferred, fallback to project-level)..."
if ! attempt_repo_binding "serviceAccount:${RUNTIME_SA_EMAIL}" "roles/artifactregistry.reader"; then
  add_project_binding_with_retry "serviceAccount:${RUNTIME_SA_EMAIL}" "roles/artifactregistry.reader" || warn "project-level fallback grant failed"
fi

# Grant iam.serviceAccountUser on builder SA so Cloud Build service agents can impersonate it
info "Granting iam.serviceAccountUser on builder SA to Cloud Build identities..."
for sa in "${CLOUDBUILD_SA}" "${CLOUDBUILD_AGENT_SA}"; do
  if ! gcloud iam service-accounts add-iam-policy-binding "${BUILDER_SA_EMAIL}" \
    --member="serviceAccount:${sa}" --role="roles/iam.serviceAccountUser" --project="${PROJECT}" >/dev/null 2>&1; then
    warn "grant iam.serviceAccountUser may have insufficient perms or already applied for ${sa}"
  else
    info "Granted iam.serviceAccountUser to ${sa} on ${BUILDER_SA_EMAIL}."
  fi
done

# create secret if provided
if [ -n "${GROQ_API_KEY:-}" ]; then
  if ! gcloud secrets describe groq-api-key --project="${PROJECT}" >/dev/null 2>&1; then
    info "Creating secret groq-api-key..."
    gcloud secrets create groq-api-key --replication-policy="automatic" --project="${PROJECT}"
  else
    info "Secret groq-api-key exists."
  fi
  info "Adding secret version..."
  printf "%s" "${GROQ_API_KEY}" | gcloud secrets versions add groq-api-key --data-file=- --project="${PROJECT}" >/dev/null || warn "adding secret version failed"

  # Ensure runtime SA has secret accessor role on the secret (required for Cloud Run to inject)
  info "Ensuring runtime SA has Secret Manager access to 'groq-api-key' (roles/secretmanager.secretAccessor)..."
  # Check current policy for the secret
  if gcloud secrets get-iam-policy groq-api-key --project="${PROJECT}" >/dev/null 2>&1; then
    if gcloud secrets get-iam-policy groq-api-key --project="${PROJECT}" --format="json" | grep -q "\"serviceAccount:${RUNTIME_SA_EMAIL}\""; then
      info "Runtime SA already present in secret IAM policy."
    else
      if gcloud secrets add-iam-policy-binding groq-api-key --member="serviceAccount:${RUNTIME_SA_EMAIL}" --role="roles/secretmanager.secretAccessor" --project="${PROJECT}" >/dev/null 2>&1; then
        info "Granted roles/secretmanager.secretAccessor to ${RUNTIME_SA_EMAIL} on secret groq-api-key."
      else
        warn "Failed to grant roles/secretmanager.secretAccessor to ${RUNTIME_SA_EMAIL} on groq-api-key (insufficient perms?)."
        info "Attempting project-level fallback: grant roles/secretmanager.secretAccessor on the project to runtime SA (best-effort)."
        if gcloud projects add-iam-policy-binding "${PROJECT}" --member="serviceAccount:${RUNTIME_SA_EMAIL}" --role="roles/secretmanager.secretAccessor" >/dev/null 2>&1; then
          info "Granted roles/secretmanager.secretAccessor to ${RUNTIME_SA_EMAIL} at project level as fallback."
        else
          warn "Project-level fallback grant failed. You will need to grant roles/secretmanager.secretAccessor to ${RUNTIME_SA_EMAIL} manually."
        fi
      fi
    fi
  else
    warn "Unable to read secret IAM policy for groq-api-key; secret may not exist or you may lack permission."
  fi
fi

# Poll for builder SA visibility
info "Polling for builder SA visibility in repo or project IAM..."
SEEN=false
for i in $(seq 1 18); do
  if gcloud artifacts repositories get-iam-policy "${REPO}" --location="${REGION}" --project="${PROJECT}" --format="yaml" 2>/dev/null | grep -q "serviceAccount:${BUILDER_SA_EMAIL}"; then
    info "Builder SA visible in repo policy."
    SEEN=true
    break
  fi
  if gcloud projects get-iam-policy "${PROJECT}" --format="yaml" 2>/dev/null | grep -q "serviceAccount:${BUILDER_SA_EMAIL}"; then
    info "Builder SA visible in project policy."
    SEEN=true
    break
  fi
  info "builder SA not visible yet (attempt ${i}/18)."
  sleep 10
done
if [ "$SEEN" != "true" ]; then
  warn "Builder SA not visible; continuing but build may fail."
fi

# Build via cloudbuild.yaml
info "Preparing cloudbuild config..."
CLOUDBUILD_TMP="$(mktemp /tmp/cloudbuild.bootstrap.XXXX.yaml)"
cat > "${CLOUDBUILD_TMP}" <<EOF
steps:
  - id: "build"
    name: "gcr.io/cloud-builders/docker"
    args: ["build", "-t", "${IMAGE}", "."]
  - id: "push"
    name: "gcr.io/cloud-builders/docker"
    args: ["push", "${IMAGE}"]
images:
  - "${IMAGE}"
options:
  logging: CLOUD_LOGGING_ONLY
EOF

BUILDER_SA_FOR_API="${BUILDER_SA_RESOURCE}"

info "Starting build+push using builder SA (${BUILDER_SA_EMAIL})..."
gcloud config set project "${PROJECT}" >/dev/null

MAX_ATTEMPTS=6
DELAY=10
attempt=1
BUILD_OK=false
while [ $attempt -le $MAX_ATTEMPTS ]; do
  info "Build attempt ${attempt}/${MAX_ATTEMPTS}..."
  if gcloud builds submit --project="${PROJECT}" --region="${REGION}" --config="${CLOUDBUILD_TMP}" --service-account="${BUILDER_SA_FOR_API}" .; then
    info "Build & push successful: ${IMAGE}"
    BUILD_OK=true
    break
  else
    warn "Build attempt ${attempt} failed. Sleeping ${DELAY}s..."
    sleep $DELAY
    attempt=$((attempt+1))
    DELAY=$((DELAY*2))
  fi
done

rm -f "${CLOUDBUILD_TMP}" || true

if [ "$BUILD_OK" != "true" ]; then
  fatal "Build failed after ${MAX_ATTEMPTS} attempts."
fi

# persist TF_IMAGE_TAG in .env
if grep -q '^TF_IMAGE_TAG=' .env 2>/dev/null; then
  sed -i.bak 's|^TF_IMAGE_TAG=.*|TF_IMAGE_TAG="'"${IMAGE}"'"|' .env
else
  echo "TF_IMAGE_TAG=${IMAGE}" >> .env
fi
info "Persisted TF_IMAGE_TAG=${IMAGE} in .env"

info "Bootstrap complete. Run './scripts/deploy.sh' to create/update Cloud Run."
exit 0
