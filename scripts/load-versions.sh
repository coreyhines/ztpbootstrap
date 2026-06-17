#!/bin/bash
# Source pinned container image tags from versions.env (repo root).
# Usage: source scripts/load-versions.sh && load_versions_env [/path/to/repo]

load_versions_env() {
    local repo_dir="$1"
    if [[ -z "$repo_dir" ]]; then
        repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi
    local versions_file="${repo_dir}/versions.env"

    if [[ -f "$versions_file" ]]; then
        # shellcheck disable=SC1090
        source "$versions_file"
    fi

    NGINX_IMAGE="${NGINX_IMAGE:-docker.io/nginx:1.30.2}"
    POSTGRES_IMAGE="${POSTGRES_IMAGE:-docker.io/library/postgres:17.10-alpine}"
    WEBUI_IMAGE="${WEBUI_IMAGE:-registry.fedoraproject.org/fedora:44}"
    KEA_IMAGE="${KEA_IMAGE:-ztpbootstrap-kea:3.0.3}"
}
