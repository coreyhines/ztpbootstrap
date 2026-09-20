#!/usr/bin/env bash
# Install reviewed worker code from this checkout. Does not restart the ZTP pod.
set -euo pipefail

usage() {
    printf 'Usage: %s [--check]\nInstall the rootful host network worker; --check only validates prerequisites.\n' "$0"
}

install_socket_policy() (
    # Keep the existing privileged host-service role, but give this worker a
    # distinct peer type. The connecting container remains confined.
    local policy_dir
    policy_dir="$(mktemp -d)"
    trap 'rm -rf -- "${policy_dir}"' EXIT
    cat > "${policy_dir}/ztp_network_worker.te" <<'POLICY'
policy_module(ztp_network_worker, 1.0.0)
type ztp_network_worker_t;
domain_type(ztp_network_worker_t)
role system_r types ztp_network_worker_t;
unconfined_domain(ztp_network_worker_t)
gen_require(`
    type init_t;
    type bin_t;
    type container_t;
')
allow init_t ztp_network_worker_t:process transition;
allow ztp_network_worker_t bin_t:file entrypoint;
allow container_t ztp_network_worker_t:unix_stream_socket connectto;
POLICY
    make -C "${policy_dir}" -f /usr/share/selinux/devel/Makefile ztp_network_worker.pp
    semodule -i "${policy_dir}/ztp_network_worker.pp"
    install -d -o root -g root -m 0755 \
        /etc/systemd/system/ztpbootstrap-network-worker.service.d
    printf '[Service]\nSELinuxContext=system_u:system_r:ztp_network_worker_t:s0\n' \
        > "${policy_dir}/selinux.conf"
    install -o root -g root -m 0644 "${policy_dir}/selinux.conf" \
        /etc/systemd/system/ztpbootstrap-network-worker.service.d/selinux.conf
)

main() {
    local check_only=0 command source_dir target module effective_uid
    readonly target=/usr/local/lib/ztpbootstrap
    case "${1:-}" in
        --check) check_only=1 ;;
        -h|--help) usage; return 0 ;;
        '') ;;
        *) usage >&2; return 2 ;;
    esac
    if (( $# > 1 )); then usage >&2; return 2; fi
    for command in id dirname realpath install chmod systemctl python3 podman; do
        command -v "${command}" >/dev/null 2>&1 || { printf 'Error: %s required\n' "${command}" >&2; return 1; }
    done
    effective_uid="$(id -u)"
    if [[ "${effective_uid}" != 0 ]]; then
        printf 'Error: rootful host installation requires root.\n' >&2
        return 1
    fi
    source_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
    if [[ ! -d /run/systemd/system ]]; then
        printf 'Error: run on the Linux systemd host, outside the WebUI container.\n' >&2
        return 1
    fi
    python3 -I -c 'import yaml' || {
        printf 'Error: install the distribution python3 PyYAML package first (Fedora: python3-pyyaml).\n' >&2
        return 1
    }
    podman info --format '{{.Host.Security.Rootless}}' | {
        read -r rootless
        [[ "${rootless}" == false ]] || { printf 'Error: only rootful Podman is supported.\n' >&2; exit 1; }
    }
    if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
        for command in semanage restorecon semodule make checkmodule mktemp rm cat; do
            command -v "${command}" >/dev/null 2>&1 || { printf 'Error: %s required for persistent SELinux labels.\n' "${command}" >&2; return 1; }
        done
        [[ -f /usr/share/selinux/devel/Makefile ]] || {
            printf 'Error: install selinux-policy-devel, policycoreutils-python-utils, checkpolicy and make.\n' >&2
            return 1
        }
    fi
    local modules=(network_jobs network_deploy network_config network_utils network_validation config_manager dhcp_config dhcp_utils)
    for module in "${modules[@]}"; do
        [[ -f "${source_dir}/webui/${module}.py" && ! -L "${source_dir}/webui/${module}.py" ]] || {
            printf 'Error: missing or symlinked worker module: %s\n' "${module}" >&2; return 1;
        }
    done
    if (( check_only )); then
        printf 'Host prerequisites present. Verify socket connectivity after installation.\n'
        return 0
    fi
    # Stop only the independent worker before updating its trusted module set.
    # Its graceful shutdown waits for any in-flight transaction and rollback.
    if systemctl is-active --quiet ztpbootstrap-network-worker.service; then
        systemctl stop ztpbootstrap-network-worker.service
    fi
    [[ ! -L "${target}" ]] || { printf 'Error: worker install path must not be a symlink.\n' >&2; return 1; }
    install -d -o root -g root -m 0755 "${target}"
    for module in "${modules[@]}"; do
        install -o root -g root -m 0444 "${source_dir}/webui/${module}.py" "${target}/${module}.py"
    done
    install -o root -g root -m 0444 "${source_dir}/scripts/network-host-worker.py" "${target}/worker.py"
    chmod 0555 "${target}"
    install -d -o root -g root -m 0700 /run/ztpbootstrap /var/lib/ztpbootstrap-network-worker
    if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
        install_socket_policy
        # Label the inode; the policy above separately permits peer connection.
        semanage fcontext -a -t container_file_t '/var/run/ztpbootstrap(/.*)?' 2>/dev/null || \
            semanage fcontext -m -t container_file_t '/var/run/ztpbootstrap(/.*)?'
        restorecon -RF /run/ztpbootstrap "${target}"
    fi
    install -o root -g root -m 0644 "${source_dir}/systemd/ztpbootstrap-network-worker.service" \
        /etc/systemd/system/ztpbootstrap-network-worker.service
    systemctl daemon-reload
    systemctl enable --now ztpbootstrap-network-worker.service
    printf 'Worker installed. Install the reviewed WebUI quadlet mount before testing container connectivity.\n'
    printf 'SELinux: verify capabilities() inside the WebUI; if denied, inspect ausearch -m avc -ts recent.\n'
    printf 'Do not disable SELinux or report host apply ready until that probe succeeds.\n'
}

trap 'printf "Worker installation failed at line %s.\n" "$LINENO" >&2' ERR
main "$@"
