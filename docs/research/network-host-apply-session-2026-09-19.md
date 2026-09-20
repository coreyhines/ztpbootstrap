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

## Attribution (in progress)

| Bucket | Planned backend/model | Resolved backend/model | Agent/log | Commit | Status |
|---|---|---|---|---|---|
| H1 | ollama-local-cli / qwen3.8:27b-mlx | same | /tmp/ollama-bucket-H1.log | pending | running |
| H2 | codex-cli / gpt-6-astra | native subagent (approved adapter) | pending | pending | waiting |
| H3 | ollama-cloud-cli / kimi-k3:cloud | pending | pending | pending | waiting |

Coordinator planning commit: `47d6507`. Capacity snapshot:
`pb-sessions/network-host-apply/execute-before.json`.
