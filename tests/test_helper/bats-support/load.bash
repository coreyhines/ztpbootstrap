# bats-support - Supporting library for Bats test helpers
# This is a minimal implementation for our tests

load() {
    # Minimal load function - just source the file if it exists
    local file="$1"
    if [[ -f "$file" ]]; then
        source "$file"
    fi
}
