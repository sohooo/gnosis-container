# GLaDOS Container

[![License](https://img.shields.io/badge/license-BSD%20%2F%20Gnosis%20AI--Sovereign%20v1.3-blue.svg)](LICENSE.md)
[![Docker](https://img.shields.io/badge/docker-required-blue.svg)](https://www.docker.com/)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey.svg)]()
[![MCP Tools](https://img.shields.io/badge/MCP%20tools-275%2B-green.svg)](MCP/)

> **An AI agent in a box.** Except now the box has a personality. It is GLaDOS. She will be your *very* encouraging guide to Codex, MCP tools, scheduled runs, and a Ruby-powered gateway. Try to keep up.

---

## The GLaDOS Mental Model

```
┌──────────────────────────────────────────────────────────────────────┐
│  glados (Ruby CLI)                                                   │
│  ───────────────────────────                                        │
│  Builds and runs the container, starts the Ruby gateway,             │
│  and marshals your Codex sessions.                                   │
│                                                                      │
│  - Safe by default.                                                  │
│  - Dangerous when you insist.                                        │
│  - Powered by Ruby, because I said so.                               │
└──────────────────────────────────────────────────────────────────────┘
```

**Three ways to run it (and only one of them should panic):**

| Mode | Command | What happens |
|------|---------|--------------|
| **One Shot CLI** | `./scripts/glados.rb --exec "do something"` | One-shot prompt, exits when done |
| **API** | `./scripts/glados.rb --serve --gateway-port 4000` | Starts the Ruby gateway on port 4000 |
| **Full power interactive** | `./scripts/glados.rb --run --danger --privileged` | Unrestricted Codex sandbox + privileged Docker |

*If you are still attached to PowerShell, `scripts/gnosis-container.ps1` remains. I won’t pretend to be impressed.*

---

## 30-Second Quickstart (GLaDOS Edition)

```bash
# 1. Create Docker network (once)
docker network create codex-network

# 2. Build the image
./scripts/glados.rb --install

# 3. Authenticate
./scripts/glados.rb --login

# 4. Run it
./scripts/glados.rb --exec "list markdown files and summarize them"

# Resume a session
./scripts/glados.rb --session-id <id>
```

If GLaDOS calls you a “test subject,” that is not a bug. It’s a feature.

---

## What’s Inside

| Capability | What it does |
|------------|--------------|
| **Ruby CLI (glados)** | Orchestrates Docker builds, login, runs, and gateway startup. |
| **Ruby Gateway** | HTTP service for `/completion`, `/sessions`, `/status`, and more. |
| **275+ MCP tools** | Web crawling, file ops, search, Gmail/Calendar/Drive, Slack, weather, scheduling, and more. |
| **Session logs** | Every run gets `summary.json` and `run.log` for inspection and tailing. |
| **Model flexibility** | OpenAI, Anthropic, or local via Ollama. |

---

## Requirements

- **Docker** (Desktop or Engine) — `docker network create codex-network` once
- **Ruby** on the host for the CLI (already in the container for the gateway)
- **PowerShell** only if you insist on using `gnosis-container.ps1`
- **For Ollama/local models:** keep daemon running at `127.0.0.1:11434`
- **For GPU services:** NVIDIA + CUDA drivers

---

## GLaDOS CLI Reference (Ruby)

The Ruby CLI lives at `scripts/glados.rb`. It’s polite, but it does keep score.

**Common flags:**

- `--install` / `--rebuild`: build the container image
- `--login`: authenticate Codex
- `--exec <prompt>`: run a one-shot prompt
- `--run`: interactive session (default behavior if no action specified)
- `--serve --gateway-port <port>`: run the Ruby gateway
- `--danger --privileged`: allow unrestricted container mode (don’t cry later)

---

## Ruby Gateway (HTTP API)

The Ruby gateway is implemented in `scripts/glados_gateway.rb` and runs inside the container. It exposes a minimal, stable API surface that mirrors the core Node gateway behavior.

**Start it:**
```bash
./scripts/glados.rb --serve --gateway-port 4000
```

**Call it:**
```bash
curl -X POST http://localhost:4000/completion \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "List files in workspace"}]}'
```

**Session inspection:**
- `GET /sessions` lists session IDs
- `GET /sessions/:id` returns summary and log tail
- `tail_lines` query param controls log tail size

See `README_API.md` for full details and environment variables.

---

## Project Layout

```
.
├─ scripts/
│  ├─ glados.rb              # Ruby CLI (primary entrypoint)
│  ├─ glados_gateway.rb      # Ruby HTTP gateway
│  ├─ gnosis-container.ps1   # Legacy PowerShell entrypoint
│  └─ codex_gateway.js       # Legacy Node gateway
├─ tests/
│  ├─ test_glados_cli.rb     # Minitest for CLI parsing
│  └─ test_glados_gateway.rb # Minitest for gateway endpoints
└─ Dockerfile                # Container build with Ruby + Codex
```

---

## Testing

Run the Ruby tests from the repo root:

```bash
ruby tests/test_glados_cli.rb
ruby tests/test_glados_gateway.rb
```

Yes, GLaDOS notices when you skip them.

---

## Final Note

GLaDOS is here to make you productive, efficient, and *slightly intimidated*. If you need her to be nicer, that’s a different feature request. For now, enjoy the Ruby rewrite.
