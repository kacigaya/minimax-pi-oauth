#!/usr/bin/env bash
set -euo pipefail

# MiniMax OAuth -> Pi installer
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/kacigaya/minimax-pi-oauth/main/install.sh | bash

APP_NAME="minimax-pi-oauth"
APP_DIR="${MINIMAX_PI_OAUTH_DIR:-$HOME/.minimax-pi-oauth}"
AUTH_PATH="${MINIMAX_PI_OAUTH_AUTH:-$APP_DIR/auth.json}"
REGION="${MINIMAX_PI_OAUTH_REGION:-global}"
PI_AGENT_DIR="${PI_AGENT_DIR:-$HOME/.pi/agent}"
HELPER="$APP_DIR/minimax-pi-oauth.py"
KEY_SCRIPT="$PI_AGENT_DIR/minimax-pi-oauth-token.sh"
PI_MODELS_JSON="$PI_AGENT_DIR/models.json"
RAW_URL="https://raw.githubusercontent.com/kacigaya/minimax-pi-oauth/main/install.sh"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd python3
need_cmd mkdir
need_cmd chmod

if [[ "$REGION" != "global" && "$REGION" != "cn" ]]; then
  echo "MINIMAX_PI_OAUTH_REGION must be 'global' or 'cn'." >&2
  exit 1
fi

if ! command -v pi >/dev/null 2>&1; then
  echo "Warning: pi command not found. Install Pi first:" >&2
  echo "  npm install -g @earendil-works/pi-coding-agent" >&2
fi

mkdir -p "$APP_DIR" "$PI_AGENT_DIR"
chmod 700 "$APP_DIR" "$PI_AGENT_DIR" 2>/dev/null || true

cat > "$HELPER" <<'PY'
#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser
from pathlib import Path

CLIENT_ID = "78257093-7e40-4613-99e0-527b14b39113"
SCOPE = "group_id profile model.completion"
REFRESH_MARGIN_SECONDS = 60
DEFAULT_AUTH_PATH = Path(os.environ.get("MINIMAX_PI_OAUTH_AUTH", str(Path.home() / ".minimax-pi-oauth" / "auth.json")))
REGIONS = {
    "global": {
        "portal": "https://api.minimax.io",
        "base_url": "https://api.minimax.io/anthropic",
    },
    "cn": {
        "portal": "https://api.minimaxi.com",
        "base_url": "https://api.minimaxi.com/anthropic",
    },
}


class MiniMaxOAuthError(RuntimeError):
    pass


def b64url(data):
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def code_challenge(verifier):
    return b64url(hashlib.sha256(verifier.encode("ascii")).digest())


def now():
    return int(time.time())


def auth_path(args):
    return Path(args.auth_path).expanduser()


def load_auth(path):
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_auth(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def remove_auth(path):
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def parse_expiry(value):
    if value is None:
        return now() + 3600
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return now() + 3600
    if numeric > 10_000_000_000:
        return int(numeric / 1000)
    if numeric > 1_000_000_000:
        return int(numeric)
    return now() + int(numeric)


def request_form(method, url, payload=None, headers=None, timeout=30, redirects=3):
    body = None
    request_headers = {
        "accept": "application/json",
        "user-agent": "minimax-pi-oauth/1.0",
        "x-request-id": str(uuid.uuid4()),
    }
    if headers:
        request_headers.update(headers)
    if payload is not None:
        body = urllib.parse.urlencode(payload).encode("utf-8")
        request_headers["content-type"] = "application/x-www-form-urlencoded"
    request = urllib.request.Request(url, data=body, headers=request_headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        if exc.code in {301, 302, 303, 307, 308} and redirects > 0:
            location = exc.headers.get("Location")
            if location:
                next_url = urllib.parse.urljoin(url, location)
                return request_form(method, next_url, payload, headers, timeout, redirects - 1)
        raw = exc.read().decode("utf-8", "replace")
        raise MiniMaxOAuthError(f"HTTP {exc.code} from {url}: {raw}") from exc
    except urllib.error.URLError as exc:
        raise MiniMaxOAuthError(f"Failed to reach {url}: {exc.reason}") from exc
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise MiniMaxOAuthError(f"Invalid JSON from {url}: {raw[:200]}") from exc


def normalize_token_response(region, token):
    access_token = token.get("access_token")
    refresh_token = token.get("refresh_token")
    if not access_token:
        raise MiniMaxOAuthError(f"Token response did not include access_token: {token}")
    return {
        "region": region,
        "portal": REGIONS[region]["portal"],
        "base_url": REGIONS[region]["base_url"],
        "client_id": CLIENT_ID,
        "access_token": access_token,
        "refresh_token": refresh_token,
        "expires_at": parse_expiry(token.get("expired_in") or token.get("expires_in")),
        "created_at": now(),
    }


def extract_user_code_response(response):
    data = response.get("data") if isinstance(response.get("data"), dict) else response
    user_code = data.get("user_code") or data.get("code")
    verification_uri = (
        data.get("verification_uri_complete")
        or data.get("verification_url")
        or data.get("verification_uri")
        or data.get("authorize_url")
        or data.get("auth_url")
    )
    interval_raw = int(data.get("interval") or 2000)
    interval = max(1, interval_raw / 1000 if interval_raw > 100 else interval_raw)
    expires_in = int(data.get("expires_in") or data.get("expired_in") or 600)
    if not user_code or not verification_uri:
        raise MiniMaxOAuthError(f"OAuth code response missing user code or verification URL: {response}")
    return user_code, verification_uri, interval, expires_in, data


def login(args):
    region = args.region
    portal = REGIONS[region]["portal"]
    verifier = b64url(secrets.token_bytes(48))
    state = secrets.token_urlsafe(24)
    payload = {
        "response_type": "code",
        "client_id": CLIENT_ID,
        "scope": SCOPE,
        "code_challenge": code_challenge(verifier),
        "code_challenge_method": "S256",
        "state": state,
    }
    response = request_form("POST", f"{portal}/oauth/code", payload)
    user_code, verification_uri, interval, expires_in, code_data = extract_user_code_response(response)
    if code_data.get("state") != state:
        raise MiniMaxOAuthError("MiniMax OAuth state mismatch.")

    print(f"MiniMax login code: {user_code}", file=sys.stderr)
    print(f"Open: {verification_uri}", file=sys.stderr)
    if not args.no_browser:
        try:
            webbrowser.open(verification_uri)
        except Exception:
            pass

    deadline = time.monotonic() + expires_in
    token_payload = {
        "client_id": CLIENT_ID,
        "grant_type": "urn:ietf:params:oauth:grant-type:user_code",
        "user_code": user_code,
        "code_verifier": verifier,
    }
    while time.monotonic() < deadline:
        time.sleep(interval)
        try:
            token_response = request_form("POST", f"{portal}/oauth/token", token_payload)
        except MiniMaxOAuthError as exc:
            text = str(exc).lower()
            if any(marker in text for marker in ("authorization_pending", "slow_down", "pending")):
                if "slow_down" in text:
                    interval += 2
                continue
            raise
        token_data = token_response.get("data") if isinstance(token_response.get("data"), dict) else token_response
        if token_data.get("error") in {"authorization_pending", "slow_down"}:
            if token_data.get("error") == "slow_down":
                interval += 2
            continue
        status = token_data.get("status")
        if status == "error":
            raise MiniMaxOAuthError(f"MiniMax OAuth reported an error: {token_data}")
        if status and status != "success":
            continue
        auth = normalize_token_response(region, token_data)
        save_auth(auth_path(args), auth)
        print(f"Saved MiniMax OAuth credentials to {auth_path(args)}", file=sys.stderr)
        return 0
    raise MiniMaxOAuthError("Timed out waiting for MiniMax OAuth approval.")


def refresh(args, force=False):
    path = auth_path(args)
    auth = load_auth(path)
    if not auth:
        raise MiniMaxOAuthError(f"No MiniMax OAuth credentials found at {path}. Run login first.")
    if not force and auth.get("access_token") and int(auth.get("expires_at", 0)) - now() > REFRESH_MARGIN_SECONDS:
        return auth
    refresh_token = auth.get("refresh_token")
    if not refresh_token:
        raise MiniMaxOAuthError("No refresh_token found. Run login again.")
    region = auth.get("region") or args.region
    portal = REGIONS.get(region, REGIONS["global"])["portal"]
    response = request_form("POST", f"{portal}/oauth/token", {
        "client_id": CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
    })
    token_data = response.get("data") if isinstance(response.get("data"), dict) else response
    if token_data.get("status") and token_data.get("status") != "success":
        raise MiniMaxOAuthError(f"MiniMax OAuth refresh failed: {token_data}")
    updated = normalize_token_response(region, {**token_data, "refresh_token": token_data.get("refresh_token") or refresh_token})
    save_auth(path, updated)
    return updated


def token(args):
    auth = refresh(args, force=False)
    access_token = auth.get("access_token")
    if not access_token:
        raise MiniMaxOAuthError("No access_token found. Run login again.")
    print(access_token)
    return 0


def status(args):
    auth = load_auth(auth_path(args))
    if not auth:
        print("not logged in")
        return 1
    remaining = int(auth.get("expires_at", 0)) - now()
    state = "valid" if remaining > REFRESH_MARGIN_SECONDS else "refresh needed"
    print(f"{state}: region={auth.get('region', 'unknown')} expires_in={max(0, remaining)}s")
    return 0


def logout(args):
    remove_auth(auth_path(args))
    print(f"Removed {auth_path(args)}")
    return 0


def main():
    parser = argparse.ArgumentParser(description="MiniMax OAuth helper for Pi")
    parser.add_argument("--auth-path", default=str(DEFAULT_AUTH_PATH))
    parser.add_argument("--region", choices=sorted(REGIONS), default=os.environ.get("MINIMAX_PI_OAUTH_REGION", "global"))
    sub = parser.add_subparsers(dest="command", required=True)
    login_parser = sub.add_parser("login")
    login_parser.add_argument("--region", choices=sorted(REGIONS), default=os.environ.get("MINIMAX_PI_OAUTH_REGION", "global"))
    login_parser.add_argument("--no-browser", action="store_true", default=os.environ.get("MINIMAX_PI_OAUTH_NO_BROWSER") == "1")
    sub.add_parser("token")
    sub.add_parser("status")
    refresh_parser = sub.add_parser("refresh")
    refresh_parser.add_argument("--force", action="store_true")
    sub.add_parser("logout")
    args = parser.parse_args()
    if args.command == "login":
        return login(args)
    if args.command == "token":
        return token(args)
    if args.command == "status":
        return status(args)
    if args.command == "refresh":
        refresh(args, force=args.force)
        return 0
    if args.command == "logout":
        return logout(args)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MiniMaxOAuthError as exc:
        print(f"minimax-pi-oauth: {exc}", file=sys.stderr)
        raise SystemExit(1)
PY
chmod 700 "$HELPER"

cat > "$KEY_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec python3 "$HELPER" --auth-path "$AUTH_PATH" --region "$REGION" token
EOF
chmod 700 "$KEY_SCRIPT"

if [[ ! -f "$AUTH_PATH" ]]; then
  echo "No MiniMax OAuth credentials found at $AUTH_PATH."
  echo "Starting MiniMax login..."
  login_args=(--auth-path "$AUTH_PATH" --region "$REGION" login --region "$REGION")
  if [[ "${MINIMAX_PI_OAUTH_NO_BROWSER:-}" == "1" ]]; then
    login_args+=(--no-browser)
  fi
  "$HELPER" "${login_args[@]}"
else
  echo "Keeping existing $AUTH_PATH"
fi

if ! "$KEY_SCRIPT" >/dev/null; then
  echo "MiniMax token helper failed. Re-run login:" >&2
  echo "  $HELPER --auth-path \"$AUTH_PATH\" --region \"$REGION\" login --region \"$REGION\"" >&2
  exit 1
fi

python3 - "$PI_MODELS_JSON" "$KEY_SCRIPT" "$REGION" <<'PY'
import json, pathlib, sys

models_path, key_script, region = sys.argv[1:4]
path = pathlib.Path(models_path)
if path.exists() and path.read_text(encoding="utf-8").strip():
    data = json.loads(path.read_text(encoding="utf-8"))
else:
    data = {}

base_url = {
    "global": "https://api.minimax.io/anthropic",
    "cn": "https://api.minimaxi.com/anthropic",
}[region]
providers = data.setdefault("providers", {})
zero = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}

def model(mid, name):
    return {
        "id": mid,
        "name": name,
        "reasoning": True,
        "input": ["text"],
        "contextWindow": 204800,
        "maxTokens": 131072,
        "cost": zero,
    }

providers["minimax-pi-oauth"] = {
    "name": "MiniMax OAuth",
    "baseUrl": base_url,
    "api": "anthropic-messages",
    "apiKey": f"!{key_script}",
    "authHeader": True,
    "headers": {
        "x-api-key": f"!{key_script}"
    },
    "models": [
        model("MiniMax-M2.7", "MiniMax M2.7 OAuth"),
        model("MiniMax-M2.7-highspeed", "MiniMax M2.7 High Speed OAuth"),
    ],
}
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
chmod 600 "$PI_MODELS_JSON" 2>/dev/null || true

echo
echo "Pi provider installed: minimax-pi-oauth"
echo "Auth: $AUTH_PATH"
echo "Token helper: $KEY_SCRIPT"
echo "Use Pi: pi --model minimax-pi-oauth/MiniMax-M2.7"
echo
echo "Login again: $HELPER --auth-path \"$AUTH_PATH\" --region \"$REGION\" login --region \"$REGION\""
echo "One-liner: curl -fsSL $RAW_URL | bash"
