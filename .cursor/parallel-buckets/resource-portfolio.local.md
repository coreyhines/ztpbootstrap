# ztpbootstrap — Parallel Buckets resource portfolio

## Project defaults

- **Integration branch:** `feature/runtime-ztp-network`
- **Farm base:** current integration HEAD at schedule approval
- **Live MCP buckets:** fedora1 SSH, OPNsense MCP — Cursor/operator only

## Routing overrides

| Profile | Notes |
|---------|--------|
| `live_mcp` | Cursor auto or operator — never Ollama |
| `serialize` | Claude CLI sonnet preferred for UI + API coupling |
| `pure_logic` / `read_tools` | Ollama-local on Mac (`qwen3.6:35b-a3b-mxfp8`) |
| `mock_fixtures` | Ollama-local fast (`gemma4:12b-mlx`) |

## Enforcement

Coordinators **must not** implement approved buckets inline unless:

1. `resolve_bucket_route.py` or farm attempt is logged in the session report, and
2. Reroute reason is documented (capacity RED, farm failed twice, MCP-only).
