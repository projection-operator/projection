#!/usr/bin/env bash
# Reports what needs maintenance: Kubernetes versions in the CI matrix, Go support,
# Makefile tool pins, and known vulnerabilities in the latest release binary.
#
# Usage: hack/maintenance-audit.sh [--publish]
#
# Prints the report. With --publish, also updates the open "Maintenance audit" issue,
# or opens one if something needs attention. A source that can't be read fails the
# run, so a network or parsing problem can't look like a clean report.

set -euo pipefail

publish=false
case "${1:-}" in
  --publish) publish=true;;
  "") ;;
  *) echo "usage: $0 [--publish]" >&2; exit 2;;
esac

repo="${GITHUB_REPOSITORY:-projection-operator/projection}"
title="Maintenance audit"
label="maintenance"
govulncheck_version="v1.9.0"
today=$(date -u +%F)

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
report="$workdir/report.md"

attention=()
notes=()
details=""

fetch() {
  curl -fsSL --max-time 30 --retry 3 "$1"
}

need() {
  if [[ -z "$2" ]]; then
    echo "ERROR: could not read $1" >&2
    exit 1
  fi
}

check_kubernetes() {
  local matrix cycles supported cycle eol minor
  matrix=$(sed -n 's/^ *k8s: *\[\(.*\)\]$/\1/p' .github/workflows/ci.yml \
    | tr -d ' ' | tr ',' '\n' | sed 's/\.[0-9]*$//')
  need "the k8s matrix in ci.yml" "$matrix"

  cycles=$(fetch https://endoflife.date/api/kubernetes.json)
  supported=$(jq -r --arg today "$today" \
    '.[] | select(.eol == false or .eol >= $today) | [.cycle, (.eol | tostring)] | @tsv' <<<"$cycles")
  need "supported Kubernetes versions" "$supported"

  while IFS=$'\t' read -r cycle eol; do
    if ! grep -qxF "$cycle" <<<"$matrix"; then
      attention+=("Kubernetes $cycle is supported until $eol but is not in the CI matrix.")
    fi
  done <<<"$supported"

  for minor in $matrix; do
    eol=$(jq -r --arg c "$minor" '.[] | select(.cycle == $c) | .eol' <<<"$cycles")
    if [[ -z "$eol" ]]; then
      attention+=("Kubernetes $minor is in the CI matrix but endoflife.date does not list it.")
    elif [[ "$eol" < "$today" ]]; then
      notes+=("Kubernetes $minor is in the CI matrix and reached end of life on $eol.")
    fi
  done
}

check_go() {
  local current minor releases newest latest_patch
  current=$(awk '$1 == "go" {print $2; exit}' go.mod)
  need "the Go version in go.mod" "$current"
  minor=$(cut -d. -f1,2 <<<"$current")

  # go.dev lists only the supported releases, newest first.
  releases=$(fetch 'https://go.dev/dl/?mode=json')
  newest=$(jq -r '.[0].version // empty' <<<"$releases")
  need "supported Go versions" "$newest"
  latest_patch=$(jq -r --arg p "go$minor." '[.[].version | select(startswith($p))][0] // empty' <<<"$releases")

  if [[ -z "$latest_patch" ]]; then
    attention+=("go.mod is on Go $current, and Go $minor is no longer supported. The newest release is ${newest#go}.")
    return
  fi
  if [[ "go$current" != "$latest_patch" ]]; then
    notes+=("go.mod is on Go $current. The latest Go $minor patch is ${latest_patch#go}.")
  fi
  if [[ "$latest_patch" != "$newest" ]]; then
    notes+=("Go ${newest#go} is available. Go $minor loses support when the next minor version ships.")
  fi
}

makefile_pin() {
  sed -n "s/^$1 ?= //p" Makefile
}

# A newer patch is informational. A newer minor or major needs attention.
check_pin() {
  local name="$1" pin="$2" source_repo="$3" latest
  need "the $name pin" "$pin"
  latest=$(gh api "repos/$source_repo/releases/latest" --jq .tag_name)
  latest="${latest##*/}" # kustomize tags look like kustomize/v5.8.3
  need "the latest $name release" "$latest"

  if [[ "$pin" == "$latest" ]]; then
    return
  fi
  if [[ "${pin%.*}" == "${latest%.*}" ]]; then
    notes+=("$name is pinned to $pin. The latest patch is $latest.")
  else
    attention+=("$name is pinned to $pin. The latest release is $latest.")
  fi
}

check_tools() {
  check_pin kustomize "$(makefile_pin KUSTOMIZE_VERSION)" kubernetes-sigs/kustomize
  check_pin controller-tools "$(makefile_pin CONTROLLER_TOOLS_VERSION)" kubernetes-sigs/controller-tools
  check_pin golangci-lint "$(makefile_pin GOLANGCI_LINT_VERSION)" golangci/golangci-lint
  check_pin crd-ref-docs "$(makefile_pin CRD_REF_DOCS_VERSION)" elastic/crd-ref-docs
  check_pin helm-unittest \
    "$(sed -n 's|.*--version \(v[0-9.]*\) https://github.com/helm-unittest/.*|\1|p' Makefile)" \
    helm-unittest/helm-unittest

  local envtest controller_runtime expected
  envtest=$(makefile_pin ENVTEST_VERSION)
  need "the ENVTEST_VERSION pin" "$envtest"
  controller_runtime=$(awk '$1 == "sigs.k8s.io/controller-runtime" {print $2; exit}' go.mod)
  need "the controller-runtime version in go.mod" "$controller_runtime"
  expected="release-$(cut -d. -f1,2 <<<"${controller_runtime#v}")"
  if [[ "$envtest" != "$expected" ]]; then
    attention+=("ENVTEST_VERSION is $envtest, but controller-runtime $controller_runtime matches $expected.")
  fi
}

check_release_binary() {
  local tag archive output rc=0
  tag=$(gh release view --repo "$repo" --json tagName --jq .tagName)
  need "the latest release tag" "$tag"
  archive="projection_${tag#v}_linux_amd64.tar.gz"

  gh release download "$tag" --repo "$repo" --dir "$workdir" --pattern "$archive" --pattern checksums.txt
  (cd "$workdir" && shasum -a 256 --check --ignore-missing --status checksums.txt)
  tar -xzf "$workdir/$archive" -C "$workdir" manager

  # Installed rather than `go run`, which would replace govulncheck's exit code with 1.
  GOBIN="$workdir/bin" go install "golang.org/x/vuln/cmd/govulncheck@$govulncheck_version"

  # govulncheck exits 3 when it finds vulnerabilities. Anything else non-zero is a failed scan.
  output=$("$workdir/bin/govulncheck" -mode binary "$workdir/manager" 2>"$workdir/govulncheck.err") || rc=$?
  case "$rc" in
    0)
      notes+=("govulncheck found no vulnerabilities in the $tag binary.")
      ;;
    3)
      attention+=("govulncheck found vulnerabilities in the $tag binary. Output is below.")
      # Issue bodies are limited to 65536 characters.
      details=$(printf '<details><summary>govulncheck output for %s</summary>\n\n```\n%s\n```\n\n</details>\n' \
        "$tag" "$(head -c 50000 <<<"$output")")
      ;;
    *)
      cat "$workdir/govulncheck.err" >&2
      echo "ERROR: govulncheck failed with exit code $rc" >&2
      exit 1
      ;;
  esac
}

write_report() {
  {
    printf '_Updated %s by `hack/maintenance-audit.sh`' "$today"
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
      printf ' in [this run](%s/%s/actions/runs/%s)' "$GITHUB_SERVER_URL" "$repo" "$GITHUB_RUN_ID"
    fi
    printf '._\n\n'

    if [[ ${#attention[@]} -gt 0 ]]; then
      printf '## Needs attention\n\n'
      printf -- '- %s\n' "${attention[@]}"
      printf '\n'
    else
      printf 'Nothing needs attention.\n\n'
    fi

    if [[ ${#notes[@]} -gt 0 ]]; then
      printf '## For information\n\n'
      printf -- '- %s\n' "${notes[@]}"
      printf '\n'
    fi

    if [[ -n "$details" ]]; then
      printf '%s\n' "$details"
    fi
  } >"$report"
}

publish_report() {
  local number
  number=$(gh issue list --repo "$repo" --label "$label" --state open --limit 100 --json number,title \
    --jq "map(select(.title == \"$title\")) | .[0].number // empty")

  if [[ -n "$number" ]]; then
    gh issue edit "$number" --repo "$repo" --body-file "$report"
  elif [[ ${#attention[@]} -gt 0 ]]; then
    gh label create "$label" --repo "$repo" --force --color 0E8A16 \
      --description "Tracked by the monthly maintenance audit"
    gh issue create --repo "$repo" --title "$title" --label "$label" --body-file "$report"
  fi
}

check_kubernetes
check_go
check_tools
check_release_binary
write_report
cat "$report"

if $publish; then
  publish_report
fi
