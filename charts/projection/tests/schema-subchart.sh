#!/usr/bin/env bash
# Asserts the chart renders when `global` is present in its values. Helm injects
# `global` into every subchart's values (even an empty map), so a root schema with
# additionalProperties: false must declare it or the chart is unusable as a dependency.
# Runs in the chart-test CI job and is safe to invoke locally.
#
# Uses `helm template` against a real wrapper chart because the failure only appears
# when Helm merges a parent chart's values into the subchart.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

chart_version=$(awk '$1 == "version:" {print $2; exit}' "$CHART_DIR/Chart.yaml")

wrapper="$work/wrap"
mkdir -p "$wrapper/charts"
cp -R "$CHART_DIR" "$wrapper/charts/projection"

cat >"$wrapper/Chart.yaml" <<YAML
apiVersion: v2
name: wrap
version: 0.1.0
dependencies:
  - name: projection
    version: ${chart_version}
    repository: file://charts/projection
YAML

cat >"$wrapper/values.yaml" <<'YAML'
projection:
  supportedKinds:
    - apiGroup: ""
      resources: [configmaps]
YAML

direct_values="$work/direct.yaml"
cat >"$direct_values" <<'YAML'
supportedKinds:
  - apiGroup: ""
    resources: [configmaps]
YAML

# assert_renders <description> <helm template args...>
assert_renders() {
  local description="$1"
  shift

  # Capture the exit status separately. Plain `output=$(cmd || true)` would swallow it.
  local status=0 output
  output=$(helm template t "$@" 2>&1) || status=$?

  if [[ $status -ne 0 ]]; then
    echo "FAIL: $description: helm template exited $status." >&2
    echo "Output was:" >&2
    echo "$output" >&2
    exit 1
  fi

  if ! grep -q '^kind: Deployment$' <<<"$output"; then
    echo "FAIL: $description: rendered output has no Deployment." >&2
    echo "Output was:" >&2
    echo "$output" >&2
    exit 1
  fi

  echo "OK: $description."
}

assert_renders "renders as a subchart" "$wrapper"
assert_renders "renders as a subchart with global.foo=bar" "$wrapper" --set global.foo=bar
assert_renders "renders directly with global.foo=bar" "$CHART_DIR" -f "$direct_values" --set global.foo=bar
