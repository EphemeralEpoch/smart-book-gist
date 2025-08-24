#!/usr/bin/env bash
# scripts/invoke.sh
# Usage: ./invoke.sh <CLOUDRUN_URL> <SERVICE_ACCOUNT or '-'> "<PROMPT>" [TEMPERATURE] [MAX_TOKENS] [MODEL]
# Robust invocation helper:
#  - obtains an identity token (supports impersonation)
#  - unsets SSL_CERT_FILE/REQUESTS_CA_BUNDLE during curl to avoid broken/missing cert paths
#  - prints useful diagnostics and re-runs curl with verbose output on failure
set -euo pipefail

CLOUDRUN_URL="${1:?Cloud Run URL required}"
SERVICE_ACCOUNT="${2:?Service account required (use '-' to skip impersonation)}"
PROMPT="${3:?Prompt text required}"
TEMPERATURE="${4:-0.2}"
MAX_TOKENS="${5:-800}"
MODEL="${6:-}"

info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
fatal(){ printf "\033[1;31m[FATAL]\033[0m %s\n" "$*"; exit 1; }

echo "[INFO] Cloud Run URL: $CLOUDRUN_URL"
echo "[INFO] Service account (or '-'): $SERVICE_ACCOUNT"

# Ensure jq exists (we use it to build JSON)
if ! command -v jq >/dev/null 2>&1; then
  fatal "jq is required but not installed."
fi

# Obtain identity token
if [ "$SERVICE_ACCOUNT" = "-" ] || [ -z "${SERVICE_ACCOUNT:-}" ]; then
  info "No service account impersonation requested. Using current gcloud user identity token."
  if ! TOKEN=$(gcloud auth print-identity-token 2>/dev/null); then
    fatal "Failed to get identity token using current account. Run 'gcloud auth login'."
  fi
else
  info "Obtaining identity token via impersonation of ${SERVICE_ACCOUNT}..."
  # try once with impersonation, otherwise fallback to current user token
  if ! TOKEN=$(gcloud auth print-identity-token --impersonate-service-account="${SERVICE_ACCOUNT}" 2>/dev/null); then
    warn "Failed to generate identity token via impersonation of ${SERVICE_ACCOUNT}. Falling back to current user token (you may need roles/iam.serviceAccountTokenCreator)."
    if ! TOKEN=$(gcloud auth print-identity-token 2>/dev/null); then
      fatal "Failed to generate identity token via fallback. Run 'gcloud auth login' or ensure impersonation perms."
    fi
  fi
fi

# Build JSON payload safely
DATA=$(jq -n \
  --arg prompt "$PROMPT" \
  --argjson temperature "$TEMPERATURE" \
  --argjson max_tokens "$MAX_TOKENS" \
  --arg model "$MODEL" \
  '{
    prompt: $prompt,
    temperature: $temperature,
    max_tokens: $max_tokens,
    model: (if $model=="" then null else $model end)
  }')

# Temporary files for response and optional verbose trace
TMP_BODY="$(mktemp)"
TMP_TRACE="$(mktemp)"

# Run curl with SSL env vars unset in a subshell (avoids broken SSL_CERT_FILE / REQUESTS_CA_BUNDLE)
# Capture HTTP status in STATUS; if curl returns non-zero we will rerun with verbose for debug.
STATUS=""
set +e
STATUS="$( (unset SSL_CERT_FILE REQUESTS_CA_BUNDLE; curl -sS -w '%{http_code}' -o "${TMP_BODY}" -X POST "${CLOUDRUN_URL}/summarize" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${DATA}") )"
CURL_RET=$?
set -e

if [ $CURL_RET -ne 0 ]; then
  warn "curl returned non-zero (${CURL_RET}). Re-running with verbose output (first 200 lines will be shown)."
  # Re-run with verbose to capture diagnostics (still with SSL env vars unset)
  set +e
  (unset SSL_CERT_FILE REQUESTS_CA_BUNDLE; curl --verbose -X POST "${CLOUDRUN_URL}/summarize" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${DATA}" > "${TMP_BODY}" 2> "${TMP_TRACE}") || true
  set -e
  echo "----- curl verbose trace (first 200 lines) -----" >&2
  sed -n '1,200p' "${TMP_TRACE}" >&2 || true
  echo "----- end curl verbose trace -----" >&2
  STATUS="${STATUS:-000}"
fi

# Read response body
RESPONSE_BODY="$(cat "${TMP_BODY}" 2>/dev/null || true)"

# Clean temp files (but keep trace for debugging if failure)
if [ $CURL_RET -eq 0 ]; then
  rm -f "${TMP_TRACE}" || true
else
  warn "Verbose trace retained at ${TMP_TRACE} for inspection."
fi
rm -f "${TMP_BODY}" || true

# Validate output
if [ -z "${RESPONSE_BODY}" ]; then
  warn "Empty response body. HTTP status: ${STATUS:-000}"
  fatal "No response from Cloud Run. Check service URL, network, and permissions."
fi

echo "[INFO] HTTP status: ${STATUS}"
# Try to pretty-print JSON response; if that fails, print raw
if echo "${RESPONSE_BODY}" | jq . >/dev/null 2>&1; then
  echo "${RESPONSE_BODY}" | jq .
else
  warn "Response is not valid JSON; printing raw response:"
  echo "${RESPONSE_BODY}"
  fatal "Failed to parse response as JSON."
fi

echo "[INFO] Done."
exit 0
