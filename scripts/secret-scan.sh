#!/bin/bash
# Secret scanning for ztpbootstrap.
#
# Replaces the gitleaks-action and trufflehog GitHub Actions by calling the
# scanner binaries directly. Neither action is mirrored on Forgejo's action
# hosts, so a script keeps CI identical under Forgejo Actions, GitHub
# Actions, and local git hooks.
#
# CI gates on gitleaks only. Local pre-commit may still run ggshield when
# GITGUARDIAN_API_KEY is set to a valid key.
#
# Not to be confused with scripts/security-scan.sh, which runs dependency
# and DAST scans (pip-audit, bandit, ZAP) and writes a report.
set -euo pipefail

readonly MODE="${1:-}"

usage() {
  printf 'Usage: %s {pre-commit|pre-push|ci}\n' "$0" >&2
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'error: required command not found: %s\n' "$command_name" >&2
    return 1
  fi
}

run_gitleaks_staged() {
  printf 'Running gitleaks against staged changes...\n'
  gitleaks git --staged --redact=100 --no-banner --log-level warn
}

run_gitleaks_history() {
  printf 'Running gitleaks against repository history...\n'
  gitleaks git . --redact=100 --no-banner --log-level warn
}

sanitize_gitguardian_api_key() {
  local key="${GITGUARDIAN_API_KEY:-}"
  key="${key//[[:space:]]/}"
  key="${key#\"}"
  key="${key%\"}"
  key="${key#\'}"
  key="${key%\'}"
  if [[ "${key}" == [Tt][Oo][Kk][Ee][Nn]* ]]; then
    key="${key:5}"
  fi
  export GITGUARDIAN_API_KEY="${key}"
}

run_ggshield_pre_commit() {
  sanitize_gitguardian_api_key
  if [[ -z "${GITGUARDIAN_API_KEY:-}" ]]; then
    printf 'Skipping GitGuardian (GITGUARDIAN_API_KEY unset).\n'
    return 0
  fi
  printf 'Running GitGuardian pre-commit scan...\n'
  ggshield secret scan pre-commit --no-check-for-updates --fail-on-server-error
}

check_tracked_ignored_files() {
  local ignored_files

  ignored_files="$(git ls-files -ci --exclude-standard)"
  if [[ -n "$ignored_files" ]]; then
    printf 'error: tracked files match ignore rules and must be removed or unignored:\n' >&2
    printf '%s\n' "$ignored_files" >&2
    return 1
  fi
}

run_pre_commit() {
  require_command gitleaks
  check_tracked_ignored_files
  run_gitleaks_staged
  if command -v ggshield >/dev/null 2>&1; then
    run_ggshield_pre_commit
  fi
}

run_pre_push() {
  require_command gitleaks
  check_tracked_ignored_files
  run_gitleaks_history
}

run_ci() {
  require_command gitleaks
  check_tracked_ignored_files
  run_gitleaks_history
}

case "$MODE" in
  pre-commit)
    shift
    run_pre_commit "$@"
    ;;
  pre-push)
    shift
    run_pre_push "$@"
    ;;
  ci)
    shift
    run_ci "$@"
    ;;
  *)
    usage
    exit 2
    ;;
esac
