#!/usr/bin/env bash
# Drafts a release prep PR (CHANGELOG scaffold + chart/doc version bumps + categorized PR-list comment).
#
# Usage: hack/release-prep.sh --bump <patch|minor|major> [--dry-run|--no-dry-run]
#
# Default is --dry-run. With --no-dry-run, pushes a release/v<X.Y.Z>-prep branch to
# origin and opens a PR. Always operates on origin/main; the working tree is
# expected to be checked out from main (the GHA workflow guarantees this).

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 --bump <patch|minor|major> [--dry-run|--no-dry-run]
  --bump          Required. Which component to bump.
  --dry-run       (default) Print what would change; do not write or push.
  --no-dry-run    Create branch, commit, push, and open PR.
EOF
  exit 2
}

bump=""
dry_run=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bump) bump="${2:-}"; shift 2;;
    --dry-run) dry_run=true; shift;;
    --no-dry-run) dry_run=false; shift;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done

case "$bump" in
  patch|minor|major) ;;
  *) echo "--bump must be patch|minor|major (got: '$bump')" >&2; usage;;
esac

# Latest stable tag: highest semver vX.Y.Z, excluding pre-release suffixes.
latest_tag=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' \
  | grep -Ev -- '-(alpha|beta|rc)' \
  | sort -V \
  | tail -1)
if [[ -z "$latest_tag" ]]; then
  echo "no stable v*.*.* tag found" >&2; exit 1
fi

ver="${latest_tag#v}"
IFS='.' read -r major minor patch <<<"$ver"
case "$bump" in
  patch) patch=$((patch+1));;
  minor) minor=$((minor+1)); patch=0;;
  major) major=$((major+1)); minor=0; patch=0;;
esac
next_tag="v${major}.${minor}.${patch}"
next_ver="${next_tag#v}"

echo "latest tag: $latest_tag"
echo "next tag:   $next_tag (bump=$bump)"

# Refuse if the computed tag already exists on origin (protects against
# force-retag breaking goreleaser replace-mode releases).
if git ls-remote --tags origin "refs/tags/$next_tag" | grep -q .; then
  echo "ERROR: tag $next_tag already exists on origin" >&2
  echo "       (latest tag is $latest_tag — bump from there)" >&2
  exit 1
fi

# Refuse if HEAD is already at the latest tag — there's nothing new to release.
if [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$latest_tag")" ]]; then
  echo "ERROR: HEAD is at $latest_tag — nothing merged since the last release" >&2
  exit 1
fi
