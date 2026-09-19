# Host-owned network apply (#13 / #57)

Status: proposed; implementation and deployment have not started.

## Evidence

- Forgejo #13: `apply_ztp_network()` runs synchronously in Flask and stops
  `ztpbootstrap-webui.service`, terminating its own request and rollback code.
- Forgejo #57: the Podman failure's runtime cause is unconfirmed. The read-only
  socket mount is not itself a barrier to Unix socket connections. Inspect the
  actual host/client/socket/SELinux state before choosing a deployment fix.
- `api_network_apply()` saves a full configuration snapshot after the operation,
  leaving a window for overwriting concurrent configuration changes.
- `/api/network/restart` has the same process-lifetime problem.
- Current UI treats a successful HTTP response as completed apply and does not
  track a durable operation through a disconnect.

## Proposed design

Run network mutations in a dedicated host systemd worker outside the managed pod.
The authenticated, CSRF-protected UI submits a constrained apply/restart request,
receives HTTP 202 with an operation ID, and polls persistent status. A queued
request is not proof that the network was applied. Report worker unavailability
without changing active configuration.

Define transport and file permissions before implementation. Prefer a narrowly
scoped local interface over exposing host systemd or arbitrary command execution
to the container. Only fixed network operations are accepted. Client input cannot
choose commands, unit names, executable paths, or output paths. Privileged worker
code must not be writable by the WebUI. Validate input again on the host.

Serialize jobs across processes; bound request size, queue depth, and retention.
Persist queued/running/succeeded/failed/rollback-failed states atomically without
secrets. Define stale job and host reboot recovery, duplicate submissions, and
readiness reporting. A worker must not have PartOf/BindsTo dependencies that stop
it with the pod. Review how status remains available after a changed IP address;
show a reconnect destination without interpreting a lost connection as success.

Use the configuration manager's locking and atomic writes. Commit only intended
sections against fresh state. Restore managed network/quadlet/Kea state on failure
without reverting unrelated concurrent edits. Report rollback failures explicitly.
Do not mark success until the requested services and effective network are checked.

Install the worker, dependencies, permissions, and systemd units through an
idempotent documented deployment path. Preserve SELinux enforcement; diagnose
denials before proposing a narrow policy or other deployment adjustment. Do not
remove the existing socket mount without auditing remaining DHCP/status users.

## Implementation slices

1. H1: freeze transport, request/status schema, permissions, deployment ownership,
   recovery semantics, and test contract. Record read-only host diagnosis when the
   deployment host is confirmed. Stop and revise scope if evidence changes design.
2. H2: host worker, job persistence/client, transaction/rollback changes, installer,
   systemd wiring, and worker tests.
3. H3: Flask apply/restart/status integration, UI polling/reconnection, API tests,
   operator documentation, and integrated regression verification.

Merge H1 then H2 then H3. Keep file ownership explicit in the approval schedule.

## Acceptance checks

- Stopping the UI/pod does not stop the worker or lose operation results.
- Missing worker, invalid input, duplicate apply, partial stop, restart timeout,
  network failure, rollback failure, and stale jobs have explicit tested outcomes.
- Concurrent configuration updates survive successful apply and rollback.
- Authentication and CSRF remain enforced; rejected jobs make no host changes.
- Test host-bound command construction, permissions, and arbitrary-command rejection.
- Run relevant Python tests, shellcheck for changed scripts, format/lint checks,
  and a controlled Linux/Podman integration test before claiming live success.

## Scope

This proposal covers #13/#57 and the network restart endpoint. Remaining July
issues #10/#34/#27, unrelated setup bugs, and the merged podman PR #7 title are
separate follow-ups. Production deployment needs its own concrete reviewed change.

## Planning state

Capacity snapshot: `pb-sessions/network-host-apply/before.json` (legacy probe).
The project model scan found new `mtplx-local` and `mtplx-workstation` resources;
user chose to keep existing executors. Exclude both new resources from this pass.
