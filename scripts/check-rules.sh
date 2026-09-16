#!/usr/bin/env bash
#
# check-rules.sh — validate the Prometheus rules without a cluster.
#
# A PrometheusRule is a Kubernetes CRD wrapping a normal Prometheus rules file
# under .spec. `kubectl apply` validates the Kubernetes shape and says nothing
# about the PromQL inside, so a rule with a syntax error applies cleanly and
# then silently never fires. promtool is the only thing that actually parses
# the queries.
#
# Docker is the only requirement; yq and promtool both run in containers, so
# this behaves the same on a laptop and on a CI agent.
#
#   ./scripts/check-rules.sh

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rules_dir="${here}/k8s/monitoring"
work=".check"

YQ_IMAGE="mikefarah/yq:4"
PROM_IMAGE="prom/prometheus:v3.1.0"

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running; cannot run promtool." >&2
  exit 2
fi

mkdir -p "${rules_dir}/${work}"
trap 'rm -rf "${rules_dir:?}/${work}"' EXIT

failures=0
checked=0

shopt -s nullglob
for file in "${rules_dir}"/*rules*.yaml; do
  name="$(basename "$file")"
  echo "checking ${name}"

  # MSYS_NO_PATHCONV stops Git Bash rewriting the container-side path.
  if ! MSYS_NO_PATHCONV=1 docker run --rm -v "${rules_dir}:/w" "$YQ_IMAGE" \
        '.spec' "/w/${name}" > "${rules_dir}/${work}/${name}" 2>/dev/null; then
    echo "  could not extract .spec" >&2
    failures=$((failures + 1))
    continue
  fi

  if [ ! -s "${rules_dir}/${work}/${name}" ]; then
    echo "  .spec is empty - not a PrometheusRule?" >&2
    failures=$((failures + 1))
    continue
  fi

  # The image entrypoints to `prometheus`, so promtool needs an override.
  if MSYS_NO_PATHCONV=1 docker run --rm --entrypoint promtool \
       -v "${rules_dir}:/w:ro" "$PROM_IMAGE" \
       check rules "/w/${work}/${name}" 2>&1 | sed 's/^/  /'; then
    checked=$((checked + 1))
  else
    failures=$((failures + 1))
  fi
done

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: ${failures} rule file(s) did not validate." >&2
  exit 1
fi

if [ "$checked" -eq 0 ]; then
  echo "No rule files found in ${rules_dir}." >&2
  exit 1
fi

echo "All ${checked} rule file(s) valid."
