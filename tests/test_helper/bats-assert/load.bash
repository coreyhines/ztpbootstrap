# bats-assert - Assertion library for Bats
# Minimal implementation for our tests

assert_success() {
    if [[ $status -ne 0 ]]; then
        echo "Expected success but got exit code $status"
        return 1
    fi
}

assert_failure() {
    if [[ $status -eq 0 ]]; then
        echo "Expected failure but got success"
        return 1
    fi
}

assert_output() {
    local pattern="$1"
    if [[ "$output" =~ $pattern ]]; then
        return 0
    else
        echo "Output does not match pattern: $pattern"
        echo "Actual output: $output"
        return 1
    fi
}
