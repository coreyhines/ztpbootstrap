# Host network apply — execution report

Approved schedule: [network-host-apply-buckets.md](network-host-apply-buckets.md).
Integration branch: `feature/network-host-apply`.

## Live diagnosis (read-only)

`podwich ztpbootstrap` located all four pod containers on fedora1.freeblizz.com.
The deployed WebUI image is `hub.freeblizz.com/ztpbootstrap-webui:b4374dd`.
Inside that container, both `/usr/bin/podman` and `/usr/bin/systemctl` exist.
Connecting to `/run/podman/podman.sock` with a Python Unix socket succeeds, and
`podman ps` successfully lists host containers. Host `podman.socket` is active.
No recent AVC records were returned by the bounded audit query.

`systemctl is-active ztpbootstrap-pod.service` inside the WebUI fails with:
“System has not been booted with systemd as init system (PID 1). Can't operate.”
and “Failed to connect to system scope bus via local transport: Host is down”.
The host WebUI unit has `BindsTo=ztpbootstrap-pod.service`.

Conclusion: #57's reported Podman failure is not reproduced on the deployed image.
Host systemd access is the reproduced blocker. Simply granting it would then expose
#13's self-termination problem; the independent worker addresses both boundaries.
No production changes made.

## Verification baseline

- Python unittest discovery: 257 tests passed in 63.214 seconds.
- Local Podman VM is running Fedora with systemd 259, Python/PyYAML and SELinux
  enforcing. Available for isolated verification; no changes made yet.

## Final attribution

| Bucket | Planned backend/model | Resolved backend/model | Agent/log | Commits | Status |
|---|---|---|---|---|---|
| H1 | ollama-local-cli / qwen3.8:27b-mlx | same, plus coordinator contract review | /tmp/ollama-bucket-H1.log | a390e94, 43b765b | integrated |
| H2 | codex-cli / gpt-6-astra | native Codex subagent, plus coordinator SELinux installer | /root/h2_host_worker | 3905a91, 4e0ec3d | integrated |
| H3 | ollama-cloud-cli / kimi-k3:cloud | cloud farm twice, then coordinator completion | /tmp/ollama-bucket-H3.log; /tmp/network-host-apply-H3-retry.log | 4e0ec3d | integrated |

H1's farm prose incorrectly called itself inline; the actual farm log/metrics
confirm local Ollama execution. Its security contract required coordinator fixes
(host-only state, trusted imports, correct ConfigManager signature, viable socket
permissions, no invented SELinux policy, and honest duplicate/recovery semantics).

The first capacity probe reached Codex 97%; the user said "continue". A proposed
cloud reroute was withdrawn before execution after a fresh probe showed reset.
H2 ran on the originally assigned agent; it wrote code/tests/recovery interlock,
then its final follow-up errored with an actual usage limit. Coordinator committed
its work and completed the installer after isolated policy testing. No H2 cloud
farm occurred.

H3 first failed on a cloud read timeout, preserving partial API edits. Retry reached
45 rounds without a final answer. Coordinator preserved API/UI/tests, repaired
input handling and incorrect tests, corrected misleading lost-response messages,
added recovery-control behavior, completed runbook/integration checks, and committed.
H3 worktree remains at `/Users/corey/code/ztpbootstrap-bucket-H3-ollama` with original
uncommitted farm output for attribution; integrated, reviewed versions are in the
main checkout. H1's clean worktree was removed by its farm wrapper.

## Final verification

- Python regression: **307 tests passed** in 64.128s (baseline 257).
- Linux Fedora VM: **34** worker/transaction tests passed on Python 3.14.
- Changed Python files: black and Ruff clean; installer/BATS shellcheck clean.
- `make test-ci`: **23 passed**, zero failed.
- `make lint`: shellcheck passed; yamllint unavailable and skipped by Makefile.
- Node syntax/behavior checks passed for pending/verified UI states, safe IPv4/IPv6
  reconnect links, persisted job ID, and ambiguous-submit outcomes.
- API: 24 tests cover auth/CSRF,202,400,409,503,status IDs, and no in-Flask mutations.
- `bats tests/integration/test_network_api.bats`: nine skipped because no deployed
  local WebUI service. Live restart test is explicitly opt-in.
- No visual browser QA: browser Node execution tool unavailable in this session.

Isolated SELinux test initially reproduced PermissionError with socket inode
`container_file_t` and default worker `unconfined_service_t`. A minimal CIL trial
was insufficient and discarded. The verified reference-policy module grants a
separate `ztp_network_worker_t` host domain the trusted host-service role, with
container connectto permission scoped to that peer type. The container remains
confined; enforcement never disabled. The embedded installer policy builds the
same tested module using distribution policy-devel tools and persists its context.

Actual product `run_worker` ran under a transient systemd service with that domain;
a restricted rootful container imported the real NetworkJobClient and successfully
queried capabilities (host Podman version) and empty status. Worker stopped afterward;
temporary policy removed from the local VM. Test images and temporary QA source
remain cached; production was untouched.

This verifies protocol/process isolation and policy connectivity, not a real
production network migration. Rollout must install worker + matching image/quadlet
and verify a controlled live apply/rollback. Do not close production acceptance
based solely on unit tests. The complete installer was not run on the immutable VM;
its policy build and runtime path were tested separately in a disposable Fedora
builder and host systemd service.

## Economics

Snapshot span is 337 minutes and includes user/tool approval waits and quota resets;
it is not farm runtime or attributable usage. Other sessions can affect provider
counters. The negative deltas reflect resets and cannot represent token savings.

### Economics (capacity snapshot)

| Provider | Before | After | Delta | Source |
|----------|--------|-------|-------|--------|
| anthropic | 100% / 0% | 76% / 0% | -24 pt / +0 pt | — |
| cursor | — | — | — | — |
| ollama-cloud | — | — | — | — |
| codex | 25% / 54% | 10% / 66% | -15 pt / +12 pt | chatgpt.json |

| Metric | Value |
|--------|-------|
| Snapshot before | `2026-09-19T22:15:29.122872+00:00` |
| Snapshot after | `2026-09-20T03:52:29.757031+00:00` |
| Wall clock (snapshot span) | 337.0 min |
| Capacity probe | `legacy` |


### Measured farm usage

- H1: 27 rounds; 15,854 completion tokens; 712,457 prompt tokens; 1577.2s measured model time.
- H3 retry: 45 rounds; 46,551 completion tokens; 2,225,136 prompt tokens; 512.9s measured model time.
