# bugscrub-2026-09-fixes — bucket plan

Generated from: Forgejo issues reviewed 2026-09-19 (coreyhines/ztpbootstrap), the `bug-scrub-2026-09` tranche plus related older issues. No separate spec; each bucket below cites its issues, which serve as the spec.
Integration branch: `feature/bugscrub-2026-09-fixes` (from `main` @ `e90a5b3`)
Coordinator: Claude Code (Opus 5)

## Approval status

| Field | Value |
|-------|-------|
| Status | **`approved`** |
| Approved by | user ("approve", 2026-09-19) |
| Approved waves | all (1, 2, 3) |
| Notes | |

**Do not farm or implement until status is `approved` or `approved_wave_N`.**

## Session status

| Field | Value |
|-------|-------|
| **Level** | GREEN |
| **Updated** | 2026-09-19 19:41 UTC |
| **Claude session / week %** | 11% / 0% |
| **Cursor total / API %** | unreadable (`no_session_cookie`); treated as unknown, not blocked |
| **Codex / ChatGPT Plus** | session 0%, week 16%; `codex_status --auth` ok |
| **Ollama cloud** | limits unreadable (`no_cloud_cookie`) |
| **Ollama local** | idle (`/api/ps` empty); thermal guard tools present |
| **Capacity probe** | `legacy` |
| **Before snapshot** | `docs/research/pb-sessions/bugscrub-2026-09-fixes/before.json` |

## Bucket registry (schedule)

| Wave | ID | Title | Profile | Anthropic | Owner | Backend | Model | Exec | Files (own) | Depends on |
|------|----|-------|---------|-----------|-------|---------|-------|------|-------------|------------|
| 1 | N1 | nginx: publish-only docroot + single server block + HTTPS redirect | write_crud | sonnet | claude-opus | claude-cli | opus | — | `nginx.conf` | — |
| 1 | W1 | Serve webui with gunicorn on 127.0.0.1; fix rate-limiter identity | write_crud | sonnet | codex-default | codex-cli | gpt-6-astra | — | `webui/start-webui.sh`, `webui/requirements.txt`, `webui/Containerfile`, `webui/rate_limiter.py`, `systemd/ztpbootstrap-webui.container`, `tests/unit/test_rate_limiter.py` (new) | — |
| 1 | C1 | ConfigManager: atomic locked RMW, real timeout, unique backups, 0600 | write_crud | opus | claude-opus ⚠ override | claude-cli | opus | — | `webui/config_manager.py`, `webui/cvaas_config.py`, `tests/unit/test_config_manager.py`, `tests/unit/test_cvaas_config.py` | — |
| 1 | D1 | Kea generator: v6 SNTP, OUI allow/block, relay subnets, subnet ids | write_crud | opus | cursor-auto | cursor-cli | auto | — | `webui/dhcp_config.py`, `tests/unit/test_dhcp_config.py` | — |
| 1 | D2 | DHCP validator path + v6-only readiness | pure_logic | sonnet | ollama-local | ollama-local-cli | qwen3.8:27b-mlx ⚠ | — | `webui/dhcp_validation.py`, `webui/dhcp_deploy.py`, `tests/unit/test_dhcp_validation.py`, `tests/unit/test_dhcp_deploy_status.py` | — |
| 1 | K1 | Network apply: check systemctl rc; full rollback | write_crud | sonnet | cursor-auto ⚠ override | cursor-cli | auto | — | `webui/network_deploy.py`, `tests/unit/test_network_deploy.py` | — |
| 1 | M1 | Make lint/format and CI shellcheck actually fail | pure_logic | none | ollama-cloud ⚠ override | ollama-cloud-cli | kimi-k3:cloud ⚠ | — | `Makefile`, `.forgejo/workflows/ci.yml` | — |
| 1 | A1 | app.py security: auth gate, config redaction, upload cap, legacy compare, bind | write_crud | opus | codex-default | codex-cli | gpt-6-astra | — | `webui/app.py`, `tests/unit/test_app_security.py` (new) | — |
| 2 | A2 | app.py: route config writes through ConfigManager; log cap; stale v4 conf | write_crud | opus | claude-opus | claude-cli | opus | — | `webui/app.py`, `tests/unit/test_app_config_writes.py` (new) | C1, A1 |
| 3 | I1 | Integration merge + full unit/lint gate | integration_merge | none | coordinator | inline | opus | inline | merge only | all |

### Probe overrides (disclosed)

- **C1 → claude-opus** (probe: `ollama-cloud`). C1 is concurrency and locking correctness (#17/#18). I want the strongest reasoning here, and Ollama Cloud limits are unreadable (`no_cloud_cookie`), which the skill treats as ask-user. Swapped with M1 so the pool spread is unchanged.
- **M1 → ollama-cloud** (probe: `claude-opus`). This is mechanical Makefile/CI work and a good fit for a cheap pool. It takes C1's slot.
- **K1 → cursor-auto** (probe: `cursor-named-opus`). Named Opus on Cursor is `api_metered`, and Cursor usage is unreadable. Auto uses the included pool. Cursor now has two buckets (D1, K1), both on the included pool.
- **Model tags ⚠:** the distribute probe still reports the old June tags (`qwen3.6:35b-a3b-mxfp8`, `kimi-k2.7-code:cloud`) even though the new `models.choices` are saved. The likely cause is `OLLAMA_FARM_*` env defaults taking precedence. At farm time I will export `OLLAMA_FARM_LOCAL_MODEL=qwen3.8:27b-mlx` and `OLLAMA_FARM_CLOUD_MODEL=kimi-k3:cloud` so the farms use what you chose. This deserves an issue on the parallel-buckets repo.

## Execution status (2026-09-19)

All buckets **merged** into `feature/bugscrub-2026-09-fixes`. Commits: C1 `61ac558`, N1 `7990f7f`, A1 `9c867f6`, W1 `0925f8f`, D1 `01b53e7`, K1 `9a63d13` (+`ad08c05`), M1 `9afd2b2` (+`96abe2c`), D2 `3604e20`, A2 `6774fc6`. Final gate: 257 tests OK; ruff, black and shellcheck clean. C1/N1/A2 ran as native Claude sub-agents (see the session report for why).

## Merge order

```text
Wave 1: N1 ∥ W1 ∥ C1 ∥ D1 ∥ D2 ∥ K1 ∥ M1 ∥ A1   (all file-disjoint)
        merge order: C1 → A1 → W1 → N1 → D1 → D2 → K1 → M1
Wave 2: A2   (needs C1's ConfigManager API and A1's app.py)
Wave 3: I1   combined gate on the integration branch
```

## Bucket briefs

Shared rules for every bucket:
- Edit only your owned files. If a fix needs another file, stop and report it instead of editing it.
- Gate: `cd tests/unit && python3 -m unittest discover -s . -p "test_*.py"`, `ruff check webui/ tests/unit/`, `black --check webui/ tests/unit/`. Use `pip install -r webui/requirements.txt` in a venv if deps are missing.
- One commit per bucket on your bucket branch: `fix(<scope>): … (bucket <ID>, closes #N)`. No pushing and no PRs; the coordinator merges.
- Nothing touches the live host (ztpboot.freeblizz.com). No deploys.

### N1 — nginx (#67, #61, #62)
- **#67:** stop serving the config dir. Replace `location / { try_files … }` with an allowlist. Serve `= /bootstrap.py` and `~ ^/[A-Za-z0-9_-]+\.py$` (alternate scripts, excluding `bootstrap_backup_*`). Keep `/health`, `/ui/`, `/api/`. Everything else `return 404`. Grep `docs/`, `README*` and `setup*.sh` for other files switches download (EOS images, etc.) and allowlist any you find, citing where you found them.
- **#61:** collapse to one HTTPS server block (`listen 443 ssl http2 default_server`, `server_name _;`), removing the hardcoded `ztpboot.example.com 10.0.0.10 2001:db8::10`. Port 80 server: `return 301 https://$host$request_uri;` for everything except `/bootstrap.py`, which stays reachable over plain HTTP because some EOS ZTP flows fetch over HTTP. Leave a comment explaining that exception.
- **#62:** raise `/api/` and `/ui/` `proxy_read_timeout` to 30s. Keep the 120s location.
- Verify: `podman run --rm -v $PWD/nginx.conf:/etc/nginx/conf.d/default.conf:ro docker.io/library/nginx:alpine nginx -t` (with a dummy cert), or `nginx -t` if available. Report which one you ran.
- Do NOT: touch setup scripts or quadlets (config paths stay the same).

### W1 — serving (#49, #12)
- Add `gunicorn` (pinned) to `webui/requirements.txt`. `start-webui.sh`: `exec gunicorn --bind 127.0.0.1:5000 --workers 1 --threads 8 --timeout 120 app:app`. Use one worker because rate-limit, lockout and log-processing state live in process memory.
- `Containerfile`: make sure gunicorn is installed (requirements already are).
- Quadlet healthcheck: keep `http://localhost:5000/api/status`; confirm it still works under the loopback bind.
- **#12:** `rate_limiter._get_client_identifier` uses `request.remote_addr` (ProxyFix already resolves it) and ignores raw XFF. Add unit tests showing that a spoofed XFF does not change identity.
- Do NOT: edit `app.py` (A1 owns the `app.run` host change).

### C1 — config layer (#17, #18, #48 timeout, #58, #67 perms)
- Writes: dump to a temp file in the same dir, `fsync`, `os.replace`. Never truncate in place (#17).
- RMW: hold one exclusive `flock` on a sidecar lock file (`config.yaml.lock`) across the whole read→mutate→write, plus the thread lock (#18). Expose `update(mutator: Callable[[dict], None])` (or `update_section`), which app.py will adopt in A2.
- `timeout`: implement via `LOCK_NB` polling, raising `TimeoutError` when it expires. Test it.
- #58: backup names use sub-second precision plus a collision suffix. Same for `cvaas_config.py` `bootstrap_backup_*`.
- New `config.yaml` files and backups get `chmod 0600`.
- Keep the existing public method signatures backward compatible.

### D1 — Kea generator (#50, #51, #65, #9, #8)
- #50: remove the gateway→`sntp-servers` emission in v6 and fix the comment.
- #51: v4 only. Add `ALLOWED_OUI`/`BLOCKED_OUI` gating. Allowed list: the subnet requires the class. Blocked list: a class with Kea `DROP` semantics, or a subnet `client-class` expression via `not member('BLOCKED_OUI')`. Pick one, document why, and test it. Use the #45 expression form (unquoted/hex), never quoted-string MAC comparisons.
- #9/#8: relay mode must keep the options built above, emit **all** relay subnets, and select them with Kea's native subnet `"relay": {"ip-addresses": [...]}` rather than undefined `RELAY_*` classes. Delete `configure_giaddr_matching` (or keep it only if still referenced) and update its tests.
- #65: the generator uses `dhcp_subnet_id_for_service`-compatible ids. Simplest option: delete the config lookup and use the constants everywhere.
- Do NOT: touch `dhcp_deploy.py` or `app.py`.

### D2 — validation + readiness (#53, #54)
- #53: validate `dhcp.options.custom`. Keep accepting legacy `dhcp.custom` if present. Test that a protected option code is rejected.
- #54: the readiness loop and status summary derive the expected daemons from which of `kea-dhcp4.conf` / `kea-dhcp6.conf` exist (or from the generated config). A v6-only deployment is healthy. Test both paths.

### K1 — network apply (#14, #16)
- Check `returncode` on every `systemctl stop/start`. Raise with stderr on failure so `restart_ztp_stack` returns `(False, msg)`.
- Rollback restores the pod quadlet **and** `config.yaml` from the backup, regenerates Kea configs from the **restored** config, recreates a removed podman network if the backup's pod file references one, and restarts with the restored config. Tests mock subprocess and podman (see the existing `test_network_deploy.py` pattern from #41; no real podman).
- Do NOT: address #13 (the WebUI stopping itself). Out of scope.

### M1 — lint gates (#60, #30, #31)
- Makefile: remove `|| true` from lint; yamllint should fail if it is installed and reports errors. `format`: `black bootstrap.py webui/ tests/unit/`.
- ci.yml: remove `|| true` and `2>/dev/null` from the shellcheck steps (keep `-S error`).
- Run the new gates locally. If existing scripts fail `shellcheck -S error`, **do not edit them**. List the failures in your report; the coordinator decides.

### A1 — app.py security (#46, #47, #66, #59, #49 bind)
- #46: `@app.before_request` gate. Requests to `/api/*` need auth, except an allowlist: `/api/auth/status`, `/api/auth/login`, `/api/status`. Grep `webui/static`/`webui/templates` JS for calls made before login and adjust the allowlist, justifying each entry. Keep existing `@require_auth` decorators.
- #47: `/api/config` returns `parsed` with `auth.session_secret`, `auth.admin_password_hash`, `cvaas.enroll_chars` and any `*password*` keys redacted. Drop `raw` unless the UI needs it; if it does, return a redacted dump.
- #66: `app.config["MAX_CONTENT_LENGTH"] = 10 * 1024 * 1024`.
- #59: `hmac.compare_digest` in both legacy comparisons.
- #49: `app.run(host="127.0.0.1", …)` in the `__main__` block.
- Tests: Flask test client. Unauth `/api/dhcp/leases`, `/api/logs`, `/api/device-connections` and `/api/bootstrap-script/x.py` → 401. `/api/config` never contains `session_secret`.
- Do NOT: change config-write code paths (A2).

### A2 — app.py config writes (#48, #64, #54 follow-up)
- Replace all six raw `open(CONFIG_FILE,"w")` read-modify-write sites with C1's ConfigManager update API.
- #64: bounded, ordered processed-lines store (for example an ordered list/deque persisted in order).
- #54 follow-up: when regenerating Kea configs, delete `kea-dhcp4.conf` / `kea-dhcp6.conf` for a family no longer configured.
- Tests: concurrent add-reservation + DHCP save loses no update (threads against a temp config).

## File ownership map

Each file has one owner per wave. `webui/app.py` is A1 in wave 1 and A2 in wave 2 (sequential).

## Out of scope

- #57 podman access from the webui container: needs live-host diagnosis first (commands are in the issue).
- #13 (WebUI stops itself during network apply), #22 (setup.sh HTTP-only mode), and the remaining 2026-07 issues not listed above.
- Deploying to ztpboot.freeblizz.com, and rotating secrets.
- Closed as not-a-bug or duplicate: #52, #55, #56, #63.

## Session reports

| Date | Chat posted | File |
|------|-------------|------|
| 2026-09-19 | yes | `docs/research/bugscrub-2026-09-fixes-session-2026-09-19.md` |
