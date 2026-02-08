# Codex Gateway API

> HTTP service implemented by `scripts/glados_gateway.rb`. Each request spawns a Codex process, returns when complete — and may judge you silently while doing so.

```
┌──────────────────────────────────────────────────────────────┐
│  POST /completion  →  spawns codex  →  returns result        │
│  GET  /sessions    →  list past runs                         │
│  GET  /status      →  concurrency, watcher, webhook info     │
└──────────────────────────────────────────────────────────────┘
```

**Start the gateway (GLaDOS Ruby gateway):**
```powershell
./scripts/glados.rb --serve --gateway-port 4000
```

**Legacy Node gateway (PowerShell entrypoint):**
```powershell
pwsh ./scripts/gnosis-container.ps1 -Serve -GatewayPort 4000
```

**Make a request:**
```bash
curl -X POST http://localhost:4000/completion \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "List files in workspace"}]}'
```

---

## Quick Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Liveness probe |
| `GET` | `/` | Gateway info, endpoints, config |
| `GET` | `/status` | Concurrency, uptime |
| `POST` | `/completion` | Run a prompt |
| `GET` | `/sessions` | List sessions |
| `GET` | `/sessions/:id` | Session details |

---

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CODEX_GATEWAY_PORT` | 4000 | Server port |
| `CODEX_GATEWAY_BIND` | 0.0.0.0 | Bind address |
| `CODEX_GATEWAY_MAX_BODY_BYTES` | 1048576 | Max request size (1 MiB) |
| `CODEX_GATEWAY_MAX_CONCURRENT` | 2 | Max parallel Codex runs |
| `CODEX_GATEWAY_TIMEOUT_MS` | 120000 | Default execution timeout |
| `CODEX_GATEWAY_IDLE_TIMEOUT_MS` | 900000 | Idle timeout for long-running requests |
| `CODEX_GATEWAY_MAX_TIMEOUT_MS` | 1800000 | Max allowed timeout (30 min) |
| `CODEX_GATEWAY_DEFAULT_MODEL` | *(empty)* | Default model |
| `CODEX_GATEWAY_EXTRA_ARGS` | *(empty)* | Extra CLI flags passed to Codex |
| `CODEX_GATEWAY_JSON_FLAG` | --experimental-json | JSON flag used when `json_mode` is true |
| `CODEX_GATEWAY_SESSION_DIRS` | *(varies)* | Comma-separated session directories |
| `CODEX_GATEWAY_SESSION_DIR` | *(empty)* | Single session directory override |
| `CODEX_GATEWAY_SECURE_SESSION_DIR` | *(empty)* | Directory for secure sessions |
| `CODEX_GATEWAY_SECURE_TOKEN` | *(empty)* | Token for secure sessions |

**Authentication:** None by default. Use `CODEX_GATEWAY_SECURE_TOKEN` for secure sessions or front with your own auth proxy.

---

## Endpoints

### GET /health

Liveness check.

```json
{ "status": "ok" }
```

---

### GET /

Gateway metadata: watcher config, webhook config, environment, available endpoints.

```json
{
  "status": "glados-gateway",
  "env": { "CODEX_GATEWAY_SESSION_DIRS": ["/opt/codex-home/.codex/sessions"] },
  "endpoints": {
    "health": "/health",
    "status": "/status",
    "completion": { "path": "/completion", "method": "POST" },
    "sessions": {
      "list": { "path": "/sessions", "method": "GET" },
      "detail": { "path": "/sessions/:id", "method": "GET" }
    }
  }
}
```

---

### GET /status

Extended status with concurrency, uptime, memory.

```json
{
  "concurrency": { "active": 1, "max": 2, "available": 1 },
  "uptime": 3600
}
```

---

### POST /completion

Run a prompt through Codex.

**Request:**
```json
{
  "messages": [
    { "role": "user", "content": "What files are in the workspace?" }
  ],
  "system_prompt": "You are a helpful assistant.",
  "model": "gpt-4o-mini",
  "workspace": "/workspace",
  "session_id": "optional-existing-session",
  "timeout_ms": 120000,
  "json_mode": false,
  "env": { "MY_VAR": "value" },
  "metadata": { "source": "api" }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `messages` | array | Yes* | Chat-style messages with `role` and `content` |
| `prompt` | string | Yes* | Plain string prompt (ignored if `messages` provided) |
| `system_prompt` | string | No | System instructions |
| `model` | string | No | Model override |
| `workspace` | string | No | Working directory (default `/workspace`) |
| `session_id` | string | No | Resume existing session |
| `timeout_ms` | number | No | Execution timeout |
| `json_mode` | boolean | No | Add `--experimental-json` flag |
| `env` | object | No | Per-run environment variables |
| `metadata` | object | No | Arbitrary data to persist with run |

*Either `messages` or `prompt` required.

**Response:**
```json
{
  "session_id": "session-abc123",
  "gateway_session_id": "session-abc123",
  "model": "gpt-4o-mini",
  "output": "The workspace contains...",
  "stderr": "",
  "exit_code": 0,
  "logs_path": "/opt/codex-home/.codex/sessions/gateway/session-abc123"
}
```

**Error codes:**
| Status | Meaning |
|--------|---------|
| 400 | Invalid payload or body too large |
| 408 | Timeout exceeded |
| 429 | At concurrency limit — retry later |
| 500 | Codex execution failure |

**Concurrency:** When `max_concurrent` is reached, returns 429:
```json
{
  "error": "Too many concurrent requests",
  "retry_after": 5,
  "active": 2,
  "max": 2
}
```

---

### GET /sessions

List known sessions.

**Response:**
```json
{ "sessions": ["session-abc123", "session-def456"] }
```

---

### GET /sessions/:id

Session details. Returns the summary payload if present.

**Response:**
```json
{
  "prompt": "List files in workspace",
  "output": "The workspace contains...",
  "created_at": "2025-01-15T10:30:00Z"
}
```

---

## Legacy Node gateway endpoints

The endpoints below are supported by the legacy Node.js gateway, not yet by the Ruby GLaDOS gateway.

---

### GET /sessions/:id/search

Search within session logs.

**Query params:**
| Param | Required | Description |
|-------|----------|-------------|
| `q` | Yes | Search string |
| `fuzzy` | No | Enable fuzzy matching |
| `max_results` | No | Limit results (default 5) |
| `tail_lines` | No | Cap log snippet length |

**Response:**
```json
{
  "session_id": "session-abc123",
  "query": "error",
  "signals": [
    { "line": 42, "score": 0.95, "context": "...encountered an error..." }
  ]
}
```

---

### POST /sessions/:id/prompt

Continue an existing session with a new prompt.

**Request:**
```json
{
  "prompt": "Now summarize those files",
  "system_prompt": "optional override",
  "timeout_ms": 60000
}
```

**Response:** Same as `/completion`.

---

### POST /sessions/:id/nudge

Replay a session with optional updated metadata or messages.

**Request:**
```json
{
  "prompt": "Try again with more detail",
  "messages": [...],
  "metadata": { "retry": true }
}
```

**Response:** Same as `/completion`.

---

## Trigger management (`/triggers`)

Use the new trigger API instead of editing `.codex-monitor-triggers.json`. The gateway still watches that file by default, but you can now call the API on port 4000 to list, add, update, or delete scheduled prompts. Each request accepts an optional `trigger_file` query parameter (defaults to the configured file) when you need to target a different trigger document.

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/triggers` | Return the parsed trigger array |
| `POST` | `/triggers` | Add a trigger payload (`prompt_text` + `schedule` required) |
| `PATCH` | `/triggers/:id` | Update trigger fields |
| `DELETE` | `/triggers/:id` | Remove a trigger |

Payloads mirror the scheduler schema:

```json
{
  "id": "optional-id",
  "title": "Friendly label",
  "description": "Why this runs",
  "prompt_text": "Run the latest monitor report",
  "schedule": {
    "mode": "daily",
    "time": "14:00",
    "timezone": "America/Chicago"
  },
  "enabled": true,
  "tags": ["reports"]
}
```

Each mutation persists to the trigger file and immediately refreshes the scheduler, so you can manage batches of triggers through HTTP without waiting on file-watch events.

---

## File Watcher

When enabled, file changes automatically trigger `/completion` runs.

**Enable with env vars before starting gateway:**
```powershell
$env:CODEX_GATEWAY_WATCH_PATHS = 'temp;inbox'
$env:CODEX_GATEWAY_WATCH_PROMPT_FILE = './MONITOR.md'
$env:CODEX_GATEWAY_WATCH_PATTERN = '**/*.txt'
pwsh ./scripts/gnosis-container.ps1 -Serve -GatewayPort 4000
```

| Variable | Default | Description |
|----------|---------|-------------|
| `CODEX_GATEWAY_WATCH_PATHS` | — | Paths to watch (comma/semicolon separated) |
| `CODEX_GATEWAY_WATCH_PATTERN` | `**/*` | Glob pattern |
| `CODEX_GATEWAY_WATCH_PROMPT_FILE` | — | Prompt template path |
| `CODEX_GATEWAY_WATCH_DEBOUNCE_MS` | 750 | Debounce delay |
| `CODEX_GATEWAY_WATCH_POLL_MS` | 1000 | Poll interval |
| `CODEX_GATEWAY_WATCH_USE_WATCHDOG` | false | Use watchdog implementation |
| `CODEX_GATEWAY_WATCH_SKIP_INITIAL_SCAN` | true | Skip initial file scan |

**Prompt template variables:**
| Variable | Description |
|----------|-------------|
| `{{file}}` | Changed file path |
| `{{filename}}` | File name only |
| `{{container_path}}` | Path inside container |
| `{{event_type}}` | Type of change |

Watcher status exposed via `/` and `/status`.

---

## Session Webhooks

Get notified when sessions complete.

| Variable | Description |
|----------|-------------|
| `SESSION_WEBHOOK_URL` | Webhook endpoint |
| `SESSION_WEBHOOK_TIMEOUT_MS` | Request timeout (default 5000) |
| `SESSION_WEBHOOK_AUTH_BEARER` | Bearer token |
| `SESSION_WEBHOOK_HEADERS_JSON` | Additional headers as JSON |

**Payload:**
```json
{
  "session_id": "session-abc123",
  "workspace": "/workspace",
  "prompt": "...",
  "output": "...",
  "usage": { ... },
  "metadata": { ... }
}
```

---

## Environment Variables

### Gateway Core
| Variable | Default | Description |
|----------|---------|-------------|
| `CODEX_GATEWAY_PORT` | 4000 | Server port |
| `CODEX_GATEWAY_BIND` | 0.0.0.0 | Bind address |
| `CODEX_GATEWAY_TIMEOUT_MS` | 120000 | Default timeout |
| `CODEX_GATEWAY_MAX_TIMEOUT_MS` | 1800000 | Max timeout |
| `CODEX_GATEWAY_DEFAULT_MODEL` | — | Default model |
| `CODEX_GATEWAY_EXTRA_ARGS` | — | Extra Codex CLI args |
| `CODEX_GATEWAY_JSON_FLAG` | `--experimental-json` | JSON mode flag |
| `CODEX_GATEWAY_MAX_BODY_BYTES` | 1048576 | Max request size |
| `CODEX_GATEWAY_MAX_CONCURRENT` | 2 | Max parallel runs |
| `CODEX_GATEWAY_LOG_LEVEL` | 1 | Verbosity (0-3) |

### Sessions
| Variable | Default | Description |
|----------|---------|-------------|
| `CODEX_GATEWAY_SESSION_DIRS` | — | Session directories (comma-separated) |
| `CODEX_GATEWAY_SECURE_SESSION_DIR` | `.codex-gateway-sessions/secure` | Secure session dir |
| `CODEX_GATEWAY_SECURE_TOKEN` | — | Token for secure access |
| `CODEX_GATEWAY_DEFAULT_TAIL_LINES` | 200 | Default log lines |
| `CODEX_GATEWAY_MAX_TAIL_LINES` | 2000 | Max log lines |

### Retries
| Variable | Default | Description |
|----------|---------|-------------|
| `CODEX_GATEWAY_MAX_RETRIES` | 0 | Max retry attempts |
| `CODEX_GATEWAY_RETRY_DELAY_MS` | 2000 | Base retry delay |
| `CODEX_GATEWAY_RETRY_ON_EMPTY` | false | Retry on empty response |

### Pass-through
| Variable | Description |
|----------|-------------|
| `CODEX_SANDBOX_NETWORK_DISABLED` | Passed to Codex CLI |

Full options in `scripts/codex_gateway.js`.

---

## CLI REPL

Interactive helper for calling the gateway:

```bash
python scripts/codex-repl.py http://localhost:4000
```

**Commands:**

| Command | Description |
|---------|-------------|
| `run <prompt>` | Call `/completion` |
| `list` | List sessions |
| `show <id> [events\|triggers]` | Fetch session details |
| `search <id> <phrase> [--f]` | Search session (--f for fuzzy) |
| `prompt <id> <text>` | Continue a session |
| `use <id>` | Pin session for subsequent runs |
| `timeout <seconds>` | Set default timeout |
| `mode <full\|compact>` | Toggle output mode |
| `watch <keys...>` | Show these keys in compact mode |
| `watch clear` | Reset watched keys |
| `setenv <KEY> <VALUE>` | Add/clear env overrides for future runs (`setenv clear` resets) |
| `help` | Show help |
| `clear` | Clear screen |
| `exit` / `quit` | Exit |

**Example session:**
```
codex> mode compact
codex> watch usage model
codex> setenv MY_VAR value
codex> run list markdown files
codex> use session-abc123
codex> prompt continue with summaries
```

Compact mode prints reasoning/agent messages and command outputs instead of full JSON.
