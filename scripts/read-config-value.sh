#!/bin/bash
# Read scalar values from config.yaml without requiring mikefarah/yq.
# Usage: get_config_yaml_value /path/to/config.yaml network.ipv4

get_config_yaml_value() {
    local config_file="$1"
    local dot_path="$2"
    local default="${3:-}"

    [[ -f "$config_file" ]] || return 1

    local value=""

    # Prefer mikefarah yq (not the Python jq-wrapper also named "yq").
    if command -v yq >/dev/null 2>&1; then
        if yq --version 2>&1 | grep -qiE 'mikefarah|github.com/mikefarah/yq'; then
            value=$(yq eval ".${dot_path} // \"\"" "$config_file" 2>/dev/null || echo "")
            if [[ -n "$value" ]] && [[ "$value" != "null" ]]; then
                printf '%s' "$value"
                return 0
            fi
        fi
    fi

    # Python + PyYAML when available (WebUI venv or system package).
    if command -v python3 >/dev/null 2>&1; then
        value=$(python3 - "$config_file" "$dot_path" "$default" <<'PY' 2>/dev/null || true
import sys

config_file, dot_path, default = sys.argv[1:4]
keys = [k for k in dot_path.split(".") if k]

try:
    import yaml  # type: ignore
except ImportError:
    sys.exit(1)

with open(config_file, encoding="utf-8") as handle:
    data = yaml.safe_load(handle) or {}

node = data
for key in keys:
    if not isinstance(node, dict) or key not in node:
        print(default)
        sys.exit(0)
    node = node[key]

if node is None:
    print(default)
elif isinstance(node, bool):
    print("true" if node else "false")
else:
    print(node)
PY
)
        if [[ -n "$value" ]] && [[ "$value" != "null" ]]; then
            printf '%s' "$value"
            return 0
        fi
    fi

    # Last resort: line-oriented grep for simple network.* scalars.
    case "$dot_path" in
        network.domain)
            value=$(grep -E '^[[:space:]]+domain:' "$config_file" 2>/dev/null | head -1 \
                | sed -E 's/^[[:space:]]+domain:[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d ' ')
            ;;
        network.ipv4)
            value=$(grep -E '^[[:space:]]+ipv4:' "$config_file" 2>/dev/null | head -1 \
                | sed -E 's/^[[:space:]]+ipv4:[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d ' ')
            ;;
        network.ipv6)
            value=$(grep -E '^[[:space:]]+ipv6:' "$config_file" 2>/dev/null | head -1 \
                | sed -E 's/^[[:space:]]+ipv6:[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d ' ')
            ;;
        network.network)
            value=$(grep -E '^[[:space:]]+network:' "$config_file" 2>/dev/null | head -1 \
                | sed -E 's/^[[:space:]]+network:[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d ' ')
            ;;
        network.http_only)
            value=$(grep -E '^[[:space:]]+http_only:' "$config_file" 2>/dev/null | head -1 \
                | sed -E 's/^[[:space:]]+http_only:[[:space:]]*(true|false).*/\1/')
            ;;
        network.https_port)
            value=$(grep -E '^[[:space:]]+https_port:' "$config_file" 2>/dev/null | head -1 \
                | sed -E 's/^[[:space:]]+https_port:[[:space:]]*([0-9]+).*/\1/')
            ;;
        container.host_network)
            value=$(grep -E '^[[:space:]]+host_network:' "$config_file" 2>/dev/null | head -1 \
                | sed -E 's/^[[:space:]]+host_network:[[:space:]]*(true|false).*/\1/')
            ;;
        cvaas.address)
            value=$(grep -E '^[[:space:]]+address:' "$config_file" 2>/dev/null | head -1 \
                | sed -E 's/^[[:space:]]+address:[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d ' ')
            ;;
        cvaas.enroll_chars)
            value=$(grep -E '^[[:space:]]+enroll_chars:' "$config_file" 2>/dev/null | head -1 \
                | sed -E 's/^[[:space:]]+enroll_chars:[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d ' ')
            ;;
        paths.script_dir)
            value=$(grep -E '^[[:space:]]+script_dir:' "$config_file" 2>/dev/null | head -1 \
                | sed -E 's/^[[:space:]]+script_dir:[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d ' ')
            ;;
        paths.cert_dir)
            value=$(grep -E '^[[:space:]]+cert_dir:' "$config_file" 2>/dev/null | head -1 \
                | sed -E 's/^[[:space:]]+cert_dir:[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d ' ')
            ;;
        auth.admin_password_hash)
            value=$(grep -E '^[[:space:]]+admin_password_hash:' "$config_file" 2>/dev/null | head -1 \
                | sed -E 's/^[[:space:]]+admin_password_hash:[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d ' ')
            ;;
    esac

    if [[ -n "$value" ]] && [[ "$value" != "null" ]]; then
        printf '%s' "$value"
        return 0
    fi

    [[ -n "$default" ]] && printf '%s' "$default"
    return 1
}

# Extract first IPv4/IPv6 literal from nginx server_name directives.
read_nginx_server_ips() {
    local nginx_file="$1"
    local content=""

    [[ -f "$nginx_file" ]] || return 1
    if [[ $EUID -eq 0 ]]; then
        content=$(cat "$nginx_file" 2>/dev/null)
    else
        content=$(sudo cat "$nginx_file" 2>/dev/null)
    fi
    [[ -n "$content" ]] || return 1

    local ipv4 ipv6
    ipv4=$(grep -E 'server_name' <<< "$content" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
    ipv6=$(grep -E 'server_name' <<< "$content" | grep -oE '([0-9a-fA-F:]+:+)+[0-9a-fA-F]+' | head -1 || true)

    [[ -n "$ipv4" ]] && printf 'IPV4=%s\n' "$ipv4"
    [[ -n "$ipv6" ]] && printf 'IPV6=%s\n' "$ipv6"
}
