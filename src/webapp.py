# src/webapp.py
# Minimal Flask app that listens on $PORT (Cloud Run sets it to 8080).
# - / returns a basic JSON
# - /health returns 200 for healthchecks
# - /summarize calls Groq API using groq_client.send_chat

from __future__ import annotations
import os
from flask import Flask, jsonify, request
from groq_client import send_chat

app = Flask(__name__)

@app.route("/", methods=["GET"])
def index():
    return jsonify({
        "service": "smart-book-gist",
        "status": "ok",
        "message": "Hello — the container is running and listening on the expected port."
    })

@app.route("/health", methods=["GET"])
def health():
    return ("", 200)

@app.route("/summarize", methods=["POST"])
def summarize():
    body = request.get_json(silent=True) or {}
    prompt = body.get("prompt", "No prompt provided")
    temperature = body.get("temperature", 0.2)
    max_tokens = body.get("max_tokens", 800)
    model = body.get("model")  # optional override

    from groq_client import GROQ_MODEL  # fallback default
    model = model or GROQ_MODEL

    try:
        messages = [
            {"role": "system", "content": "You are a concise, professional assistant."},
            {"role": "user", "content": prompt}
        ]
        resp = send_chat(messages=messages, model=model, temperature=temperature, max_tokens=max_tokens)
        # extract summary from response structure
        # depending on Groq API, adjust key
        summary = resp.get("choices", [{}])[0].get("message", {}).get("content") or resp
    except Exception as e:
        return jsonify({"error": "Failed to call Groq API", "details": str(e)}), 500

    return jsonify({
        "prompt": prompt,
        "gist": summary
    })

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
