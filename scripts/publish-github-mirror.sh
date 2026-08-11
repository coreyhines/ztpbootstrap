#!/usr/bin/env bash
# Push Forgejo main OR one v* tag to GitHub after CI gates.
# Modes are distinct: --tag never updates refs/heads/main.
# Usage:
#   publish-github-mirror.sh [--dry-run]
#   publish-github-mirror.sh [--dry-run] --tag v1.2.3
# Env:
#   MIRROR_GITHUB_TOKEN  required unless --dry-run
#   MIRROR_GITHUB_OWNER   default coreyhines
#   MIRROR_GITHUB_REPO    default ztpbootstrap
set -euo pipefail

DRY_RUN=0
TAG_REF=""

usage() {
  printf 'Usage: %s [--dry-run] [--tag vX.Y.Z]\n' "$(basename "$0")" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --tag)
      [[ $# -ge 2 ]] || usage
      TAG_REF="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

OWNER="${MIRROR_GITHUB_OWNER:-coreyhines}"
REPO="${MIRROR_GITHUB_REPO:-ztpbootstrap}"
TOKEN="${MIRROR_GITHUB_TOKEN:-}"

if [[ "${DRY_RUN}" -eq 0 && -z "${TOKEN}" ]]; then
  printf 'error: MIRROR_GITHUB_TOKEN is required (or pass --dry-run)\n' >&2
  exit 1
fi

if [[ -n "${TAG_REF}" && ! "${TAG_REF}" =~ ^v[0-9] ]]; then
  printf 'error: --tag must look like a release tag (v…), got %s\n' "${TAG_REF}" >&2
  exit 1
fi

if [[ -n "${TOKEN}" ]]; then
  printf '::add-mask::%s\n' "${TOKEN}"
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "${ROOT}"

# Remote URL without credentials (token goes in http.extraHeader only).
REMOTE_URL="https://github.com/${OWNER}/${REPO}.git"

# GitHub's git-over-HTTPS wants Basic with the x-access-token: prefix — the
# same header actions/checkout writes. Bearer is an Azure DevOps convention
# and is NOT accepted here.
#
# The header goes through GIT_CONFIG_* env vars rather than `git -c`, because
# `git -c "http.extraHeader=…"` puts the PAT in argv, where any user on the
# runner can read it out of `ps`. Environment is not world-readable on Linux.
#
# `base64 | tr -d '\n'` instead of `base64 -w0`: macOS base64 has no -w flag
# and this script is also run by hand during setup.
git_auth() {
  local hdr
  hdr="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${TOKEN}" | base64 | tr -d '\n')"
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=http.extraHeader \
  GIT_CONFIG_VALUE_0="${hdr}" \
    git "$@"
}

if [[ -n "${TAG_REF}" ]]; then
  TAG_SHA="$(git rev-parse "refs/tags/${TAG_REF}" 2>/dev/null || git rev-parse "${TAG_REF}")"
  printf 'Publishing tag %s (%s) to github.com/%s/%s\n' \
    "${TAG_REF}" "${TAG_SHA}" "${OWNER}" "${REPO}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf 'dry-run: would push %s:refs/tags/%s (main unchanged)\n' \
      "${TAG_SHA}" "${TAG_REF}"
    exit 0
  fi
  git_auth push "${REMOTE_URL}" "${TAG_SHA}:refs/tags/${TAG_REF}"
  printf 'Published tag %s (%s); GitHub main not modified\n' "${TAG_REF}" "${TAG_SHA}"
  exit 0
fi

# Main mode: resolve main explicitly — never use detached HEAD as main.
if git show-ref --verify --quiet refs/heads/main; then
  MAIN_SHA="$(git rev-parse refs/heads/main)"
elif git show-ref --verify --quiet refs/remotes/origin/main; then
  MAIN_SHA="$(git rev-parse refs/remotes/origin/main)"
else
  printf 'error: cannot resolve main (no refs/heads/main or origin/main)\n' >&2
  exit 1
fi

printf 'Publishing main=%s to github.com/%s/%s\n' "${MAIN_SHA}" "${OWNER}" "${REPO}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf 'dry-run: would push %s:refs/heads/main\n' "${MAIN_SHA}"
  exit 0
fi

GITHUB_MAIN="$(git_auth ls-remote "${REMOTE_URL}" refs/heads/main | awk '{print $1}')"
if [[ -n "${GITHUB_MAIN}" ]]; then
  # The first check fails harmlessly ("not a valid object name") when the
  # GitHub tip is absent locally, which is exactly the diverged case; fetch
  # it and re-check so the refusal below is a real ancestry verdict.
  #
  # No --depth here: a shallow fetch writes .git/shallow into whatever repo
  # this runs in, which would quietly truncate a developer's working clone.
  if ! git merge-base --is-ancestor "${GITHUB_MAIN}" "${MAIN_SHA}" 2>/dev/null; then
    CHECK_REF="refs/mirror-check/github-main"
    cleanup_check_ref() { git update-ref -d "${CHECK_REF}" 2>/dev/null || true; }
    trap cleanup_check_ref EXIT
    git_auth fetch --quiet "${REMOTE_URL}" "+refs/heads/main:${CHECK_REF}"
    GITHUB_MAIN="$(git rev-parse "${CHECK_REF}")"
    if ! git merge-base --is-ancestor "${GITHUB_MAIN}" "${MAIN_SHA}"; then
      printf 'error: refusing non-fast-forward publish (%s ↛ %s)\n' \
        "${GITHUB_MAIN}" "${MAIN_SHA}" >&2
      printf 'see docs/FORGEJO_GITHUB_MIRROR.md "Break-glass" before forcing anything\n' >&2
      exit 1
    fi
  fi
fi

git_auth push "${REMOTE_URL}" "${MAIN_SHA}:refs/heads/main"
printf 'Published main (%s)\n' "${MAIN_SHA}"
