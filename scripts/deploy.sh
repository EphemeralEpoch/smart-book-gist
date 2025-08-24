#!/usr/bin/env bash
# scripts/deploy.sh
# Robust Cloud Run deployer: loads .env, ensures secret IAM for runtime+compute SAs, deploys service, waits for READY with informative logs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
fatal(){ printf "\033[1;31m[FATAL]\033[0m %s\n" "$*"; exit "${2:-1}"; }

# load .env
if [ ! -f .env ]; then
  fatal ".env not found in project root. Create one (copy from .env.example)" 2
fi
set -a; source .env; set +a

# required config
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID must be set in .env}"
: "${TF_IMAGE_TAG:?TF_IMAGE_TAG must be set in .env (created by bootstrap/build)}"
GCP_REGION="${GCP_REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-smart-book-gist}"
RUNTIME_SA="${RUNTIME_SA:-${SERVICE_NAME}-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com}"
MEMORY="${CLOUDRUN_MEMORY:-256Mi}"
CONCURRENCY="${CLOUDRUN_CONCURRENCY:-1}"
TIMEOUT="${CLOUDRUN_TIMEOUT:-300s}"
ALLOW_UNAUTH="${ALLOW_UNAUTH:-true}"

retry_cmd(){
  local max_attempts="${1:-6}"; shift
  local delay="${1:-5}"; shift
  local attempt=1
  local rc=0
  local cmd=( "$@" )
  while [ $attempt -le "$max_attempts" ]; do
    if "${cmd[@]}"; then
      return 0
    else
      rc=$?
      warn "Attempt ${attempt}/${max_attempts} failed (rc=${rc}). Sleeping ${delay}s..."
      sleep "$delay"
      attempt=$((attempt+1))
      delay=$((delay*2))
    fi
  done
  return $rc
}

if ! command -v gcloud >/dev/null 2>&1; then
  fatal "gcloud CLI is required but not found in PATH."
fi
if ! command -v jq >/dev/null 2>&1; then
  fatal "jq is required but not found in PATH."
fi

info "Deploy settings: project=${GCP_PROJECT_ID} region=${GCP_REGION} service=${SERVICE_NAME} image=${TF_IMAGE_TAG} allow_unauth=${ALLOW_UNAUTH} timeout_secs=${TIMEOUT}"

# ensure project set
gcloud config set project "${GCP_PROJECT_ID}" >/dev/null

# If Secret Manager secret exists, ensure runtime SA and compute SA have secretAccessor
if gcloud secrets describe groq-api-key --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
  info "Using Secret Manager secret 'groq-api-key' for runtime GROQ_API_KEY."
  PROJECT_NUM="$(gcloud projects describe "${GCP_PROJECT_ID}" --format="value(projectNumber)")"
  COMPUTE_SA="${PROJECT_NUM}-compute@developer.gserviceaccount.com"

  for sa in "${RUNTIME_SA}" "${COMPUTE_SA}"; do
    if gcloud secrets get-iam-policy groq-api-key --project="${GCP_PROJECT_ID}" --format="json" 2>/dev/null | jq -e --arg m "serviceAccount:${sa}" '.bindings[]?.members | index($m) // empty' >/dev/null 2>&1; then
      info "Secret IAM already contains accessor for ${sa}"
    else
      info "Granting roles/secretmanager.secretAccessor to ${sa} on secret groq-api-key (idempotent)..."
      if gcloud secrets add-iam-policy-binding groq-api-key --member="serviceAccount:${sa}" --role="roles/secretmanager.secretAccessor" --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
        info "Granted secretAccessor to ${sa}"
      else
        warn "Failed to grant secretAccessor to ${sa} on secret groq-api-key (insufficient perms?). Continuing but deploy may fail."
      fi
    fi
  done
else
  info "Secret 'groq-api-key' not found; deploy will set GROQ_API_KEY from .env if present."
fi

DEPLOY_CMD=(gcloud run deploy "${SERVICE_NAME}" \
  --image="${TF_IMAGE_TAG}" \
  --platform=managed \
  --region="${GCP_REGION}" \
  --service-account="${RUNTIME_SA}" \
  --memory="${MEMORY}" \
  --concurrency="${CONCURRENCY}" \
  --timeout="${TIMEOUT}" \
  --project="${GCP_PROJECT_ID}"
)

if gcloud secrets describe groq-api-key --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
  DEPLOY_CMD+=(--update-secrets="GROQ_API_KEY=groq-api-key:latest")
else
  if [ -n "${GROQ_API_KEY:-}" ]; then
    DEPLOY_CMD+=(--set-env-vars=GROQ_API_KEY="${GROQ_API_KEY}")
  fi
fi

if [ "${ALLOW_UNAUTH}" = "true" ] || [ "${ALLOW_UNAUTH}" = "True" ]; then
  DEPLOY_CMD+=(--allow-unauthenticated)
fi

info "Running Cloud Run deploy (this may re-use existing service and create a new revision)..."
if ! "${DEPLOY_CMD[@]}"; then
  warn "gcloud run deploy failed. This may be due to missing permissions or a container-start failure."
  gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=${SERVICE_NAME}" --project="${GCP_PROJECT_ID}" --limit=50 --format="value(textPayload)" 2>/dev/null | sed -n '1,200p' || true
  fatal "Cloud Run deploy failed." 3
fi

info "Deploy command completed successfully. Waiting for service revision to become READY (timeout ${TIMEOUT})..."

MAX_WAIT="${TIMEOUT}"
if [[ $MAX_WAIT == *s ]]; then
    MAX_WAIT=${MAX_WAIT%s}
fi
MAX_WAIT=$((MAX_WAIT + 0))
INTERVAL=5
elapsed=0
ready=false

while [ $elapsed -lt $MAX_WAIT ]; do
    status_json=$(gcloud run services describe "${SERVICE_NAME}" --region="${GCP_REGION}" --project="${GCP_PROJECT_ID}" --format="json" 2>/dev/null || echo "{}")
    ready_status=$(echo "$status_json" | jq -r '.status.conditions[]? | select(.type=="Ready") | .status' 2>/dev/null || echo "")
    latest_ready_rev=$(echo "$status_json" | jq -r '.status.latestReadyRevisionName // ""' 2>/dev/null || echo "")
    traffic_total=$(echo "$status_json" | jq -r '[.status.traffic[]?.percent // 0] | add // 0' 2>/dev/null || echo 0)

    if [ "${ready_status}" = "True" ] || { [ -n "${latest_ready_rev}" ] && [ "${traffic_total}" -gt 0 ]; }; then
        info "Service Ready condition is True. ready_status:'${ready_status:-(none)}' latestReadyRev:'${latest_ready_rev:-(none)}' traffic_total:${traffic_total}"
        ready=true
        break
    fi

    info "Service not ready yet (elapsed ${elapsed}s), Ready status: ${ready_status:-(unknown)}, latestReadyRev: ${latest_ready_rev:-(none)}, traffic_total: ${traffic_total}"
    gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=${SERVICE_NAME}" --project="${GCP_PROJECT_ID}" --limit=5 --format="value(textPayload)" 2>/dev/null | sed -n '1,40p' || true

    sleep $INTERVAL
    elapsed=$((elapsed + INTERVAL))
done

if [ "$ready" != "true" ]; then
    fatal "Cloud Run revision not ready after ${MAX_WAIT}s." 4
fi

info "Service revision is READY."

SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" --region="${GCP_REGION}" --project="${GCP_PROJECT_ID}" --format="value(status.url)" || true)
info "Deploy finished. Service URL: ${SERVICE_URL:-(unknown)}"

# Retry IAM bindings after service is up
info "Ensuring IAM bindings for service account and/or allUsers..."

# Always bind runtime SA as invoker
retry_cmd 6 5 gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
  --region="${GCP_REGION}" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/run.invoker" \
  --project="${GCP_PROJECT_ID}" \
  >/dev/null 2>&1 \
  && info "Added runtime service account invoker binding." \
  || warn "Failed to add runtime service account invoker binding."

# Bind allUsers if requested
if [ "${ALLOW_UNAUTH}" = "true" ] || [ "${ALLOW_UNAUTH}" = "True" ]; then
  retry_cmd 6 5 gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
    --region="${GCP_REGION}" \
    --member="allUsers" \
    --role="roles/run.invoker" \
    --project="${GCP_PROJECT_ID}" \
    >/dev/null 2>&1 \
    && info "Added allUsers invoker binding." \
    || warn "Could not add allUsers invoker binding (organization policy or missing permission)."
fi

exit 0
