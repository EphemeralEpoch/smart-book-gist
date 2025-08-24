# src/groq_client.py
from __future__ import annotations
import os
import json
import requests
from typing import List, Dict
from pathlib import Path

# Load .env early
try:
    from dotenv import load_dotenv
    load_dotenv()
except Exception:
    pass

import certifi

GROQ_API_URL = os.getenv("GROQ_API_URL", "https://api.groq.com/openai/v1/chat/completions")
GROQ_API_KEY = os.getenv("GROQ_API_KEY")
GROQ_MODEL = os.getenv("GROQ_MODEL", "openai/gpt-oss-20b")

if not GROQ_API_KEY:
    raise RuntimeError("GROQ_API_KEY not set. Put your key in .env or export GROQ_API_KEY in your environment.")

HEADERS = {
    "Authorization": f"Bearer {GROQ_API_KEY}",
    "Content-Type": "application/json",
    "User-Agent": "groq-python-app/1.0"
}

def _effective_verify_path() -> bool | str:
    """
    Determine what 'verify' path to pass to requests:
      - If SSL_CERT_FILE or REQUESTS_CA_BUNDLE is set, use it.
      - Else if a combined bundle already exists under .certs/, use it.
      - Else return True (use system/default certs) — caller may fall back to creating bundle.
    """
    env_verify = os.getenv("SSL_CERT_FILE") or os.getenv("REQUESTS_CA_BUNDLE")
    if env_verify:
        return env_verify

    # prefer a project-local combined bundle if present
    project_local = Path.cwd() / ".certs" / "certifi_with_zscaler.pem"
    if project_local.exists():
        return str(project_local.resolve())

    # fallback: use certifi default (requests will use certifi by default if verify=True,
    # but returning True leaves requests to handle it)
    return True

def send_chat(messages: List[Dict[str, str]],
              model: str | None = None,
              temperature: float = 0.0,
              max_tokens: int | None = None,
              timeout: int = 15) -> Dict:
    payload = {
        "model": model or GROQ_MODEL,
        "messages": messages,
        "temperature": temperature,
    }
    if max_tokens is not None:
        payload["max_tokens"] = max_tokens

    verify = _effective_verify_path()

    # Make the request. If verify is True, requests uses its own cert bundle (certifi).
    # If verify is a path, requests will use that bundle.
    resp = requests.post(GROQ_API_URL, headers=HEADERS, json=payload, timeout=timeout, verify=verify)

    text = resp.text if resp is not None else ""
    if not resp.ok:
        try:
            err_json = resp.json()
        except Exception:
            err_json = text or f"{resp.status_code} {resp.reason}"
        raise RuntimeError(f"Groq API error: {err_json}")

    try:
        return resp.json()
    except Exception as e:
        raise RuntimeError(f"Failed to parse Groq response as JSON: {e}; raw: {text}")
