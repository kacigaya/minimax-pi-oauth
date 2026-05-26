<p align="center">
  <img src="logo.svg" alt="Logo" width="200">
</p>

<h1 align="center">MiniMax Pi OAuth</h1>

<p align="center">
   <strong>Simple MiniMax OAuth installer for Pi.</strong><br>
   <em>This registers MiniMax's Anthropic-compatible endpoint in Pi and uses a local
   OAuth helper to keep the access token fresh.</em>
</p>

## One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/kacigaya/minimax-pi-oauth/main/install.sh | bash
```

China region:

```bash
MINIMAX_PI_OAUTH_REGION=cn \
  curl -fsSL https://raw.githubusercontent.com/kacigaya/minimax-pi-oauth/main/install.sh | bash
```

Headless login:

```bash
MINIMAX_PI_OAUTH_NO_BROWSER=1 \
  curl -fsSL https://raw.githubusercontent.com/kacigaya/minimax-pi-oauth/main/install.sh | bash
```

## What the installer does

- Creates OAuth credentials at `~/.minimax-pi-oauth/auth.json`.
- Installs an OAuth helper at `~/.minimax-pi-oauth/minimax-pi-oauth.py`.
- Creates a Pi token helper at `~/.pi/agent/minimax-pi-oauth-token.sh`.
- Adds a `minimax-pi-oauth` Anthropic Messages provider to `~/.pi/agent/models.json`.
- Adds Pi models:
  - `minimax-pi-oauth/MiniMax-M2.7`
  - `minimax-pi-oauth/MiniMax-M2.7-highspeed`

## Use with Pi

```bash
pi --model minimax-pi-oauth/MiniMax-M2.7
```

Or inside Pi, run `/model` and choose a `minimax-pi-oauth` model.

## OAuth helper

```bash
~/.minimax-pi-oauth/minimax-pi-oauth.py status
~/.minimax-pi-oauth/minimax-pi-oauth.py login
~/.minimax-pi-oauth/minimax-pi-oauth.py refresh --force
~/.minimax-pi-oauth/minimax-pi-oauth.py logout
```

China region:

```bash
~/.minimax-pi-oauth/minimax-pi-oauth.py --region cn login --region cn
```

## Why both auth headers are configured

MiniMax's Anthropic-compatible OAuth endpoint can require both:

```text
Authorization: Bearer <token>
x-api-key: <token>
```

Pi's `authHeader: true` adds the bearer header from `apiKey`, and this installer
also configures `headers.x-api-key` to resolve the same token helper.

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `MINIMAX_PI_OAUTH_DIR` | `~/.minimax-pi-oauth` | App directory |
| `MINIMAX_PI_OAUTH_AUTH` | `~/.minimax-pi-oauth/auth.json` | OAuth credentials path |
| `MINIMAX_PI_OAUTH_REGION` | `global` | `global` or `cn` |
| `MINIMAX_PI_OAUTH_NO_BROWSER` | unset | Set to `1` for headless login |
| `PI_AGENT_DIR` | `~/.pi/agent` | Pi config directory |

## Files written

```text
~/.minimax-pi-oauth/auth.json
~/.minimax-pi-oauth/minimax-pi-oauth.py
~/.pi/agent/minimax-pi-oauth-token.sh
~/.pi/agent/models.json
```

Keep `~/.minimax-pi-oauth/auth.json` private; it contains OAuth credentials.
