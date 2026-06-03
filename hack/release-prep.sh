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

# Insert a new "## [<next_ver>] - YYYY-MM-DD" section directly above the most
# recent stable section header. Always emit empty Added/Changed/Fixed scaffolds
# for humans to fill in (matches existing CHANGELOG.md style).
mutate_changelog() {
  local target="$1"
  local today
  today=$(date +%F)

  # Find the line number of the latest stable section header (e.g. "## [0.3.2]").
  local prev_header_line
  prev_header_line=$(grep -n "^## \[${ver}\]" "$target" | head -1 | cut -d: -f1)
  if [[ -z "$prev_header_line" ]]; then
    echo "ERROR: could not find '## [${ver}]' header in $target" >&2
    return 1
  fi

  local section_file="$target.section"
  cat > "$section_file" <<EOF
## [${next_ver}] - ${today}

### Added

### Changed

### Fixed

EOF

  # awk insertion: print the new section's contents right before the matching line.
  # Read the section file once into an array, then emit it at the matched line.
  awk -v line="$prev_header_line" -v section_file="$section_file" '
    BEGIN {
      n = 0
      while ((getline s < section_file) > 0) {
        block[n++] = s
      }
      close(section_file)
    }
    NR==line {
      for (i = 0; i < n; i++) print block[i]
    }
    { print }
  ' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
  rm -f "$section_file"
}

# Replace exactly one or more occurrences of $pattern with $replacement in $file.
# Fails the whole script if the pattern is not found — drift detection.
sed_strict() {
  local file="$1" pattern="$2" replacement="$3"
  if ! grep -qE -- "$pattern" "$file"; then
    echo "ERROR: pattern not found in $file: $pattern" >&2
    return 1
  fi
  # Use a sed delimiter unlikely to appear in URLs.
  sed -i.bak "s|${pattern}|${replacement}|g" "$file" && rm -f "$file.bak"
}

mutate_chart_and_docs() {
  local root="$1"  # workdir root

  # charts/projection/Chart.yaml
  sed_strict "$root/charts/projection/Chart.yaml" \
    "^version: ${ver}$" "version: ${next_ver}"
  sed_strict "$root/charts/projection/Chart.yaml" \
    "^appVersion: \"${ver}\"$" "appVersion: \"${next_ver}\""

  # README.md
  sed_strict "$root/README.md" \
    "  --version ${ver} \\\\" "  --version ${next_ver} \\\\"
  sed_strict "$root/README.md" \
    "releases/download/v${ver}/install.yaml" \
    "releases/download/v${next_ver}/install.yaml"

  # charts/projection/README.md
  sed_strict "$root/charts/projection/README.md" \
    "--set image.tag=v${ver}" "--set image.tag=v${next_ver}"

  # docs/getting-started.md
  sed_strict "$root/docs/getting-started.md" \
    "  --version ${ver} \\\\" "  --version ${next_ver} \\\\"
  sed_strict "$root/docs/getting-started.md" \
    "releases/download/v${ver}/install.yaml" \
    "releases/download/v${next_ver}/install.yaml"

  # docs/security.md
  sed_strict "$root/docs/security.md" \
    "cosign verify ghcr.io/projection-operator/projection:v${ver}" \
    "cosign verify ghcr.io/projection-operator/projection:v${next_ver}"
  sed_strict "$root/docs/security.md" \
    "cosign verify ghcr.io/projection-operator/charts/projection:${ver}" \
    "cosign verify ghcr.io/projection-operator/charts/projection:${next_ver}"
}

# Apply all file mutations to a temp working dir, then either show diff (dry-run)
# or apply for real (live mode). This keeps mutation logic identical between modes.
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
mkdir -p "$workdir/charts/projection" "$workdir/docs"
cp CHANGELOG.md "$workdir/CHANGELOG.md"
cp charts/projection/Chart.yaml "$workdir/charts/projection/Chart.yaml"
cp charts/projection/README.md "$workdir/charts/projection/README.md"
cp README.md "$workdir/README.md"
cp docs/getting-started.md "$workdir/docs/getting-started.md"
cp docs/security.md "$workdir/docs/security.md"

mutate_changelog "$workdir/CHANGELOG.md"
mutate_chart_and_docs "$workdir"

if $dry_run; then
  echo ""
  for f in CHANGELOG.md charts/projection/Chart.yaml charts/projection/README.md README.md docs/getting-started.md docs/security.md; do
    if ! diff -q "$f" "$workdir/$f" >/dev/null; then
      echo "===== $f diff (dry-run preview) ====="
      diff -u "$f" "$workdir/$f" || true
      echo ""
    fi
  done
fi

if ! $dry_run; then
  branch="release/${next_tag}-prep"

  # Refuse to overwrite an existing branch — operator must delete first if they
  # really want to re-cut.
  if git ls-remote --heads origin "$branch" | grep -q .; then
    echo "ERROR: branch $branch already exists on origin" >&2
    echo "       (delete it first if you intend to recut: gh api -X DELETE repos/:owner/:repo/git/refs/heads/$branch)" >&2
    exit 1
  fi

  # Create branch off current HEAD (workflow guarantees this is main).
  git switch -c "$branch"

  # Apply the mutations from workdir to the real tree.
  cp "$workdir/CHANGELOG.md" CHANGELOG.md
  cp "$workdir/charts/projection/Chart.yaml" charts/projection/Chart.yaml
  cp "$workdir/charts/projection/README.md" charts/projection/README.md
  cp "$workdir/README.md" README.md
  cp "$workdir/docs/getting-started.md" docs/getting-started.md
  cp "$workdir/docs/security.md" docs/security.md

  git add CHANGELOG.md charts/projection/Chart.yaml charts/projection/README.md \
          README.md docs/getting-started.md docs/security.md

  git commit -m "release: ${next_tag} prep (CHANGELOG, chart bump, doc version strings)"
  git push origin "$branch"

  # Open the PR.
  pr_url=$(gh pr create \
    --base main --head "$branch" \
    --title "release: ${next_tag} prep (CHANGELOG, chart bump, doc version strings)" \
    --body "Prep PR for ${next_tag}. CHANGELOG scaffold awaits human prose — see the categorized PR list in the comment below." \
    --label release)

  echo "Opened PR: $pr_url"

  # Post the categorized PR-list comment.
  gh pr comment "$pr_url" --body "$comment_body"
  echo "Posted categorized PR list as a comment."
fi
