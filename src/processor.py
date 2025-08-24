"""
Process Groq response: print concise summary and save pretty JSON to file.
"""
from __future__ import annotations
import json
from pathlib import Path
from typing import Any, Dict

def summarize_choice(choice: Dict) -> str:
    # Supports OpenAI-style and variations
    content = ""
    if "message" in choice and isinstance(choice["message"], dict):
        content = choice["message"].get("content", "")
    elif "text" in choice:
        content = choice.get("text", "")
    else:
        # Fallback to stringified choice (short)
        content = json.dumps(choice)[:400]
    return content if len(content) <= 400 else content[:400] + "…"

def process_and_save(response: Dict[str, Any], out_path: str) -> None:
    print("\n=== GROQ Response Summary ===")
    if not isinstance(response, dict):
        print("Top-level response is not an object. Type:", type(response))
    else:
        keys = ", ".join(response.keys())
        print("Top-level keys:", keys)

    # choices (OpenAI-style)
    choices = response.get("choices")
    if isinstance(choices, list):
        print(f"Choices: {len(choices)}")
        for i, ch in enumerate(choices[:3], start=1):
            preview = summarize_choice(ch)
            print(f"\n[Choice {i}] Preview:\n{preview}")

    # usage
    usage = response.get("usage")
    if usage:
        print("\nUsage:")
        print(json.dumps(usage, indent=2))

    # fallback: outputs or items
    if "output" in response:
        print("\nHas 'output' key")
    if "outputs" in response:
        print("\nHas 'outputs' key (len={})".format(len(response.get("outputs")) if isinstance(response.get("outputs"), list) else "?"))

    # Save pretty JSON
    out_file = Path(out_path).expanduser().resolve()
    out_file.parent.mkdir(parents=True, exist_ok=True)
    with out_file.open("w", encoding="utf-8") as fh:
        json.dump(response, fh, indent=2, ensure_ascii=False)

    print(f"\nFull response written to: {out_file}")
    print("=== End summary ===\n")
