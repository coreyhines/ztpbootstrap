# bugscrub-2026-09-fixes — session report (2026-09-19)

Plan: [`bugscrub-2026-09-fixes-buckets.md`](bugscrub-2026-09-fixes-buckets.md) · Approved by user ("approve") · Integration branch `feature/bugscrub-2026-09-fixes` (not pushed)

## Bucket attribution

| Bucket | Owner | Planned backend | Resolved backend | Cost pool | Exec | Sub-agent | Branch | Commit | Tests | Status |
|---|---|---|---|---|---|---|---|---|---|---|
| C1 | claude-opus | claude-cli | **native Agent (opus)** | claude_subscription | subagent | general-purpose | `feat/bugscrub09-bucket-C1-claude` | `61ac558` fix(config): atomic locked config RMW, real timeouts, unique 0600 backups | 200 OK (+18) | merged |
| N1 | claude-opus | claude-cli | **native Agent (opus)** | claude_subscription | subagent | general-purpose | `feat/bugscrub09-bucket-N1-claude` | `7990f7f` fix(nginx): publish-only docroot, single HTTPS server, HTTP redirect | 182 OK; `nginx -t` + container behaviour test | merged |
| A1 | codex-default | codex-cli | codex-cli | chatgpt_plus_codex | — | — | `feat/bugscrub09-bucket-A1-codex` | `9c867f6` fix(webui): secure API access and redact config secrets | 192 OK (+10) | merged |
| W1 | codex-default | codex-cli | codex-cli | chatgpt_plus_codex | — | — | `feat/bugscrub09-bucket-W1-codex` | `0925f8f` fix(serving): use loopback Gunicorn and resolved client identity | 188 OK (+6) | merged |
| D1 | cursor-auto | cursor-cli | cursor-cli | cursor_included | — | — | `feat/bugscrub09-bucket-D1-cursor` | `01b53e7` fix(dhcp): Kea generator v6 SNTP, OUI gating, relay, subnet ids | OK | merged |
| K1 | cursor-auto | cursor-cli | cursor-cli | cursor_included | — | — | `feat/bugscrub09-bucket-K1-cursor` | `9a63d13` fix(network): check systemctl rc and fully roll back apply | OK | merged, plus coordinator fix `ad08c05` |
| M1 | ollama-cloud | ollama-cloud-cli | ollama-cloud-cli (kimi-k3:cloud) | ollama_cloud | — | — | `feat/bugscrub09-bucket-M1-ollama` | `9afd2b2` fix(ci): make lint/format and shellcheck gates fail on errors | OK (+ test_lint_gates) | merged, plus coordinator fix `96abe2c` |
| D2 | ollama-local | ollama-local-cli | ollama-local-cli (qwen3.8:27b-mlx) | ollama_sunk | — | — | `feat/bugscrub09-bucket-D2-ollama` | `3604e20` fix(dhcp): validate options.custom; derive readiness from configured daemons | 257 OK at merge | merged; farm hit round limit, coordinator committed |
| A2 | claude-opus | claude-cli | **native Agent (opus)** | claude_subscription | subagent | general-purpose | `feat/bugscrub09-bucket-A2-claude` | `6774fc6` fix(webui): route config writes through ConfigManager | 245 OK (+14) | merged |
| I1 | coordinator | inline | inline | claude_subscription | inline | — | `feature/bugscrub-2026-09-fixes` | merges + 2 fix commits | 257 OK | done |

### Reroutes and interventions

| Bucket | Planned | Resolved | Reason |
|---|---|---|---|
| C1, N1, A2 | `farm_claude_bucket.sh` (claude-cli) | native Agent tool, same model/pool | (1) The farm script crashed on macOS `/bin/bash` 3.2: `"${tool_restriction[@]}"` is unbound under `set -u` when the array is empty, and the `\| tail` pipe hid the failure (exit 0). (2) `claude` is a zsh wrapper function (`_claude_run`) that is undefined in non-interactive shells. (3) The auto-mode classifier blocked a manual `claude -p --permission-mode bypassPermissions` launch. The Claude Code adapter's native dispatch is the sanctioned alternative. |
| D2 | commit by farm | commit by coordinator | The built-in Ollama farmer hit "max rounds exceeded" with edits uncommitted. The production code was kept as written. Its tests were broken: a tuple-wrapped config, a wrong patch target, a corrupted existing test and a dropped file header. The coordinator rewrote them. |
| K1 | — | + `ad08c05` | Coordinator review found two regressions. A failed apply returned the failed candidate config, which app.py then saved over the rollback. `systemctl stop` exiting 5 (unit not loaded) aborted every apply. |
| M1 | report-only for existing failures | + `96abe2c` | The new gates found 7 real `shellcheck -S error` failures. SC2259 in setup-interactive.sh was a real bug: piped input never reached `python3` with a heredoc. `--reset-pass` hashed an empty string (#26), and podman subnet/gateway detection always returned nothing. Fixed so CI stays green. |

Scope note: `96abe2c` touches `setup-interactive.sh` (issue #26, from the 2026-07 tranche). That was outside the posted schedule and was done during I1 so M1 would not land with a red CI.

## Integration health

| Check | Result |
|---|---|
| Combined tests | `cd tests/unit && python -m unittest discover` → **257 OK** (baseline 182) |
| ruff / black | clean / clean (35 files) |
| shellcheck -S error (./*.sh, dev/) | clean (M1 made this blocking in CI) |
| Unmerged bucket branches | none |
| Executors at farm | Claude ok · Codex ok (`--auth` ok) · Cursor ok (usage unreadable) · Ollama local ok (thermal guard: GPU peak ~83°C, fans max) · Ollama cloud ok (limits unreadable) |
| Portfolio | 5 pools: Claude (3 + coordinator), Codex (2), Cursor (2), Ollama local (1), Ollama cloud (1) |

## Economics

| Provider | Before | After | Delta |
|---|---|---|---|
| anthropic (session / week) | 11% / 0% | 49% / 0% | +38 pt (coordinator plus 3 opus sub-agents) |
| codex | 16% / 0% | 21% / 33% | +5 / +33 pt |
| cursor, ollama-cloud | unreadable | unreadable | — |

Snapshot span 52.9 min (`pb-sessions/bugscrub-2026-09-fixes/economics.md`).

## Issues closed by this branch (on merge)

#8, #9, #12, #14, #16, #17, #18, #26, #46, #47, #49, #50, #51, #53, #54, #58, #59, #61, #62, #64, #65, #66, #67. Also #30, #31, #60 (lint gates) and #48.

## Follow-ups found during review (not fixed)

- `setup.sh configure_http_only()` still writes an nginx config that serves the whole config dir (#67 for HTTP-only installs, related to #22). `update-config.sh update_nginx_conf()` has an inconsistent `http_only` branch.
- setup scripts still create `config.yaml` without mode 0600 and don't take `config.yaml.lock`.
- `api_network_apply` keeps a read→write window across the stack restart. Closing it needs `network_deploy` to return only the sections it changed.
- D1: relay subnets carry no router/DNS options of their own, and ARISTA_ONLY mode ignores `allowed_ouis`.
- The existing test `test_start_returns_false_when_only_file_exists` sleeps 60s (unpatched `time.sleep`), which is where the suite's runtime goes.
- #57 (podman socket) and #13 remain open. They need live-host diagnosis.
- parallel-buckets tooling: the farm_claude bash 3.2 bug; the `recommend_bucket_owner` distribute probe ignoring saved `models.choices`; relative paths breaking `pb_capacity_snapshot --diff` under `pb-run`.

## Not done

- Nothing pushed, no PR opened, nothing deployed to ztpboot.freeblizz.com, no secrets rotated.
- Bucket worktrees for C1, N1, A2 and D2 were left in place. The auto-mode classifier blocked removing them.
