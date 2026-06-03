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

# All PRs merged into main since the latest tag's commit date.
latest_tag_date=$(git log -1 --format='%aI' "$latest_tag")
echo "PRs merged since $latest_tag ($latest_tag_date):"

# Pull merged PRs as JSON. -L 200 is plenty for any release window.
# Use strict ">" so the prior release-prep PR (which has the same mergedAt as
# the latest tag's commit, since squash-merged-and-tagged) is excluded.
prs_json=$(gh pr list \
  --base main --state merged \
  --search "merged:>$latest_tag_date" \
  --json number,title,mergedAt,author \
  -L 200)

pr_count=$(jq 'length' <<<"$prs_json")
if [[ "$pr_count" -eq 0 ]]; then
  echo "ERROR: zero merged PRs since $latest_tag — nothing to release" >&2
  exit 1
fi
echo "  found $pr_count PR(s)"

# Categorize each PR by conventional-commit prefix in the title.
# We recognize: feat, fix, build(deps), chore(deps), docs, refactor, test, ci, build, chore.
# Anything else falls into "other".
#
# Output a tab-separated table: category<TAB>number<TAB>title
categorized=$(jq -r '.[] | [.number, .title] | @tsv' <<<"$prs_json" \
  | while IFS=$'\t' read -r num title; do
      # Each type matches: type:, type(scope):, type!:, type(scope)!:
      # The "!" forms are Conventional Commits breaking-change markers —
      # critical to surface in a release-prep tool, not silently lumped into "other".
      case "$title" in
        feat:*|feat\(*\):*|feat!:*|feat\(*\)!:*)              cat=feat ;;
        fix:*|fix\(*\):*|fix!:*|fix\(*\)!:*)                  cat=fix ;;
        build\(deps\):*)                                       cat="build(deps)" ;;
        chore\(deps\):*)                                       cat="chore(deps)" ;;
        docs:*|docs\(*\):*|docs!:*|docs\(*\)!:*)              cat=docs ;;
        refactor:*|refactor\(*\):*|refactor!:*|refactor\(*\)!:*) cat=refactor ;;
        test:*|test\(*\):*|test!:*|test\(*\)!:*)              cat=test ;;
        ci:*|ci\(*\):*|ci!:*|ci\(*\)!:*)                       cat=ci ;;
        build:*|build\(*\):*|build!:*|build\(*\)!:*)          cat=build ;;
        chore:*|chore\(*\):*|chore!:*|chore\(*\)!:*)          cat=chore ;;
        *)                                                     cat=other ;;
      esac
      printf '%s\t%s\t%s\n' "$cat" "$num" "$title"
    done)

# Render the categorized list as a markdown comment.
# Categories appear in a fixed order; categories with zero entries are skipped.
order=(feat fix docs refactor build "build(deps)" chore "chore(deps)" ci test other)

build_comment_body() {
  printf '## PRs merged since %s\n\n' "$latest_tag"

  # Soft guard: warn if every PR is build(deps) or chore(deps).
  local non_deps
  non_deps=$(awk -F'\t' '$1 != "build(deps)" && $1 != "chore(deps)" {print}' <<<"$categorized" | wc -l | tr -d ' ')
  if [[ "$non_deps" -eq 0 ]]; then
    cat <<'EOF'
> [!WARNING]
> All PRs since the last tag are dependency bumps. Consider whether this release
> is warranted — per Keep a Changelog, transitive bumps have no user-facing
> effect and are typically omitted from the CHANGELOG. If you're cutting this
> patch specifically because of a security advisory in a bumped dep, say so
> in the `### Changed` section below.

EOF
  fi

  local cat
  for cat in "${order[@]}"; do
    local lines
    lines=$(awk -F'\t' -v c="$cat" '$1==c {printf "- #%s — %s\n", $2, $3}' <<<"$categorized")
    if [[ -n "$lines" ]]; then
      printf '### %s\n%s\n\n' "$cat" "$lines"
    fi
  done
}

comment_body=$(build_comment_body)

if $dry_run; then
  echo ""
  echo "===== PR comment (dry-run preview) ====="
  echo "$comment_body"
  echo "===== end preview ====="
fi
