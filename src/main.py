#!/usr/bin/env python3
"""
Entrypoint CLI for Groq Python app.
"""
from __future__ import annotations
import argparse
import os
from pathlib import Path
from datetime import datetime
from dotenv import load_dotenv
from typing import List, Dict
from groq_client import send_chat
from processor import process_and_save

# load .env if exists
load_dotenv()

DEFAULT_PROMPT = "Explain the importance of fast language models in 3 concise bullet points."

def build_messages(prompt: str) -> List[Dict[str, str]]:
    return [
        {"role": "system", "content": "You are a concise, professional assistant."},
        {"role": "user", "content": prompt}
    ]

def default_output_path(output_dir: str | None = None) -> str:
    od = output_dir or os.getenv("OUTPUT_DIR", "outputs")
    ts = datetime.utcnow().isoformat(timespec="seconds").replace(":", "-")
    return str(Path(od) / f"groq-response-{ts}.json")

def main():
    parser = argparse.ArgumentParser(description="Minimal Groq Python client")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--prompt", "-p", help="Prompt text to send")
    group.add_argument("--file", "-f", help="Path to a file containing prompt text")
    parser.add_argument("--out", "-o", help="Output file path (optional)")
    parser.add_argument("--temperature", "-t", type=float, default=0.2, help="Sampling temperature")
    parser.add_argument("--max-tokens", type=int, default=800, help="Max tokens for generation")
    parser.add_argument("--model", help="Model to use (overrides GROQ_MODEL env)")
    args = parser.parse_args()

    if args.file:
        prompt = Path(args.file).read_text(encoding="utf-8").strip()
    else:
        prompt = args.prompt or DEFAULT_PROMPT

    messages = build_messages(prompt)
    model = args.model or os.getenv("GROQ_MODEL")

    try:
        print("Sending request to Groq...")
        resp = send_chat(messages=messages, model=model, temperature=args.temperature, max_tokens=args.max_tokens)
        out_path = args.out or default_output_path()
        process_and_save(resp, out_path)
    except Exception as exc:
        print("Error:", exc)
        raise SystemExit(2)

if __name__ == "__main__":
    main()
