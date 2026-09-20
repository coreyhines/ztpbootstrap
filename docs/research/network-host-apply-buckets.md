# network-host-apply — bucket plan

Generated from: [network-host-apply-spec.md](network-host-apply-spec.md)

Approval status: approved (user follow-up: "approved", 2026-09-19; all waves)

Integration branch: `feature/network-host-apply`

## Bucket registry (schedule)

| Wave | ID | Title | Profile | Anthropic | Owner | Backend | Model | Exec | Files (own) | Depends on |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | H1 | Worker contract and recovery design | contract | sonnet | ollama-local | ollama-local-cli | qwen3.8:27b-mlx | farm | docs/research/network-host-apply-contract.md | — |
| 2 | H2 | Host worker and deployment wiring | write_crud | sonnet | codex-default | codex-cli | gpt-6-astra | subagent | webui/network_deploy.py; webui/network_jobs.py (new); scripts/network-host-worker.py (new); scripts/install-network-worker.sh (new); systemd/ztpbootstrap-network-worker.service (new); systemd/ztpbootstrap-webui.container; tests/unit/test_network_deploy.py; tests/unit/test_network_jobs.py (new) | H1 |
| 3 | H3 | Async API, UI recovery, and runbook | write_crud | sonnet | ollama-cloud | ollama-cloud-cli | kimi-k3:cloud | farm | webui/app.py; webui/templates/index.html; tests/unit/test_network_jobs_api.py (new); tests/integration/test_network_api.bats; docs/ZTP_NETWORK_HOST_SETUP.md | H2 |

Merge order: H1 → H2 → H3. Sequential waves because the host protocol and worker
must be available before integration. Coordinator reviews each result, owns this
tracker and session reports, runs combined verification, and gathers read-only host
diagnostics once the actual deployment host is confirmed. No product edits inline.

## Routing and capacity

Distribution probe with explicit project root selected mtplx-local / codex-default /
ollama-cloud. User explicitly chose existing executors on 2026-09-19. Override H1
to configured ollama-local (`qwen3.8:27b-mlx`); do not use newly detected mtplx
resources. H2 retains the selected Codex model via native subagent dispatch per
the Codex adapter, avoiding a separate CLI login. H3 retains the probe route.
Recheck route/capacity before every wave; document any proposed reroute.

Before snapshot: [before.json](pb-sessions/network-host-apply/before.json).
Legacy probe: Claude session 92%, week 0%; Codex session 43%, week 23%; Cursor
and Ollama cloud quota unavailable. Snapshot predates the model confirmation;
refresh before execution. No Claude work scheduled.

Coordinator dry-run completed: YELLOW, ask-user for all three buckets. Its planner
proposed claude-opus for every row, differing from the explicit-project distribution
probe. Override that dry-run proposal with the distributed schedule above: Claude
was already at 92% session use, the user's configured existing pools are available,
and concentrating all work on Claude would discard the distribution result.

## Acceptance and scope

All buckets follow the spec's failure, authentication, config concurrency, rollback,
and recovery requirements. H1 must resolve the exact restricted transport and
permission model, immutable worker code path, and restart/reboot lifecycle before
H2. If that requires ownership or scope changes, revise the schedule first.

H2 uses environment/configuration paths, idempotent installation, fixed service
allowlists, atomic persistent job status, and host-side revalidation. Do not use
an in-container background thread for host restart work. Include meaningful tests
for actual transaction failures and process-boundary behavior.

H3 preserves CSRF/auth, returns 202 only after durable submission, adds authenticated
job status, handles disconnect/reconnect and changed addresses honestly, and never
labels a queued job or transport timeout as successful apply. Cover both apply and
restart endpoints. Document install/update/rollback and host verification steps.

Production deployment is not part of this schedule. Live Linux/Podman verification
remains required before claiming #13/#57 resolved in production; #57 root cause
must be diagnosed, not inferred from the mount mode. Remaining #10/#34/#27,
unrelated setup bugs, and podman PR #7 title cleanup are out of scope.

## Status

Implementation complete on `feature/network-host-apply`; no production deployment.

| Bucket | Result | Commit | Executor evidence |
|---|---|---|---|
| H1 | Integrated with coordinator security corrections | a390e94, 43b765b | /tmp/ollama-bucket-H1.log |
| H2 | Integrated; coordinator completed SELinux installer after agent usage-limit error | 3905a91, 4e0ec3d | /root/h2_host_worker |
| H3 | Integrated; coordinator completed/repaired after timeout then round limit | 4e0ec3d | /tmp/ollama-bucket-H3.log; /tmp/network-host-apply-H3-retry.log |

User said "continue" after the capacity issue. A cloud reroute for H2 was announced,
then withdrawn before dispatch when Codex capacity reset. H2 did run on the originally
approved native Codex agent. It completed worker/tests/recovery lock before a later
usage-limit error. No H2 cloud execution occurred; the final SELinux installer work
was explicitly taken over by the coordinator. H3 exhausted two farm attempts;
coordinator fallback follows AGENTS.md and was announced in chat.

Verification: 307 Python tests pass; 34 worker/transaction tests also pass on Linux;
23 CI checks pass; changed Python black/ruff and shellcheck pass; JS behavior checks
pass; actual worker/client socket exchange verified under systemd and confined
Podman with SELinux enforcing. Live BATS tests skipped (no local deployed WebUI).
See execution report for complete limits and capacity economics.
