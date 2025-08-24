# scripts/setup_certs.py
from __future__ import annotations
import argparse
from pathlib import Path
import sys
import shutil
import os

try:
    import certifi
except Exception:
    print("certifi is required. Install via: pip install certifi")
    raise SystemExit(2)

ENV_PATH = Path(".env")
BACKUP_SUFFIX = ".bak"
OUT_DEFAULT = Path.cwd() / ".certs" / "certifi_with_zscaler.pem"

def find_zscaler_candidates():
    candidates = [
        Path("/etc/ssl/certs/zscaler_root.pem"),
        Path("/usr/local/share/ca-certificates/zscaler_root.crt"),
        Path("/usr/local/share/ca-certificates/zscaler_root.pem"),
    ]
    mnt = Path("/mnt/c/Users")
    if mnt.exists():
        for user in mnt.iterdir():
            cand = user / "Downloads" / "zscaler_root.cer"
            if cand.exists(): candidates.append(cand)
            cand2 = user / "Downloads" / "zscaler_root.crt"
            if cand2.exists(): candidates.append(cand2)
    return [p for p in candidates if p.exists()]

def backup_env(env_path: Path):
    if env_path.exists():
        bak = env_path.with_name(env_path.name + BACKUP_SUFFIX)
        # Avoid overwriting an existing backup
        if not bak.exists():
            shutil.copy(env_path, bak)
            print(f"Backup created: {bak}")
        else:
            print(f"Backup already exists: {bak}")
        return bak
    else:
        print("No existing .env to back up.")
        return None

def write_combined_bundle(zscaler_path: Path, out_path: Path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(certifi.where(), "rb") as cf, open(zscaler_path, "rb") as zf, open(out_path, "wb") as out:
        out.write(cf.read())
        out.write(b"\n")
        out.write(zf.read())
    print(f"Combined bundle written to: {out_path}")
    return out_path

def update_env_file(out_bundle_path: Path, env_path: Path = ENV_PATH):
    # Make a backup first
    backup_env(env_path)

    # Keys to set/update
    keys_to_set = {
        "SSL_CERT_FILE": str(out_bundle_path),
        "REQUESTS_CA_BUNDLE": str(out_bundle_path),
    }

    # Read existing lines (preserve comments & unknown keys)
    if env_path.exists():
        original_lines = env_path.read_text(encoding="utf-8").splitlines()
    else:
        original_lines = []

    new_lines = []
    found = set()

    for line in original_lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in line:
            # preserve blank lines & comments & malformed lines
            new_lines.append(line)
            continue

        k, v = line.split("=", 1)
        k_name = k.strip()
        if k_name in keys_to_set:
            # replace value for existing key
            new_lines.append(f"{k_name}={keys_to_set[k_name]}")
            found.add(k_name)
        else:
            # keep original line as-is
            new_lines.append(line)

    # append any missing keys at the end
    for k, v in keys_to_set.items():
        if k not in found:
            new_lines.append(f"{k}={v}")

    env_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    print(f".env updated (merged) with keys: {', '.join(keys_to_set.keys())}")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--zscaler", help="Path to Zscaler cert (optional)")
    p.add_argument("--out", help="Output combined bundle path (default ./.certs/certifi_with_zscaler.pem)")
    args = p.parse_args()

    out = Path(args.out) if args.out else OUT_DEFAULT

    if args.zscaler:
        zpath = Path(args.zscaler)
        if not zpath.exists():
            print("Provided zscaler cert does not exist:", zpath)
            raise SystemExit(2)
        write_combined_bundle(zpath, out)
        update_env_file(out)
        return

    candidates = find_zscaler_candidates()
    if not candidates:
        print("No Zscaler cert found in known locations. Re-run with --zscaler /path/to/zscaler_root.cer")
        print("Searched: /etc/ssl/certs/zscaler_root.pem, /usr/local/share/ca-certificates/, and Windows Downloads (WSL)")
        raise SystemExit(2)

    zpath = candidates[0]
    print("Using Zscaler cert:", zpath)
    write_combined_bundle(zpath, out)
    update_env_file(out)
    print("Done. .env was backed up to .env.bak (if it existed) and merged safely.")

if __name__ == "__main__":
    main()
