#!/usr/bin/env bash
#
# preflight.sh — verify the local toolchain before anything touches Azure.
#
# Exits non-zero if a required tool is missing, so `make preflight` can gate
# the rest of the Makefile. Optional tools are reported but never fail the run.

set -uo pipefail

REQUIRED=(git make docker az kubectl helm terraform)
OPTIONAL=(k6 kubectx k9s trivy)

missing=0

version_of() {
  case "$1" in
    git)       git --version ;;
    make)      make --version | head -1 ;;
    docker)    docker --version ;;
    az)        az version --output tsv --query '"azure-cli"' 2>/dev/null | head -1 ;;
    kubectl)   kubectl version --client --output=yaml 2>/dev/null | grep -m1 gitVersion | awk '{print $2}' ;;
    helm)      helm version --short ;;
    terraform) terraform version | head -1 ;;
    *)         "$1" --version 2>/dev/null | head -1 ;;
  esac
}

check() {
  local tool="$1" required="$2" version
  if command -v "$tool" >/dev/null 2>&1; then
    version="$(version_of "$tool" 2>/dev/null | tr -d '\r')"
    printf '  %-10s %s\n' "$tool" "${version:-installed}"
  elif [ "$required" = "required" ]; then
    printf '  %-10s MISSING\n' "$tool"
    missing=$((missing + 1))
  else
    printf '  %-10s not installed (optional)\n' "$tool"
  fi
}

echo "Required:"
for tool in "${REQUIRED[@]}"; do check "$tool" required; done

echo
echo "Optional:"
for tool in "${OPTIONAL[@]}"; do check "$tool" optional; done

echo
if command -v az >/dev/null 2>&1; then
  if subscription="$(az account show --query name --output tsv 2>/dev/null)"; then
    echo "Azure subscription: ${subscription}"
  else
    echo "Azure subscription: not signed in — run 'az login'"
    missing=$((missing + 1))
  fi
fi

echo
if [ "$missing" -gt 0 ]; then
  echo "Preflight failed: ${missing} item(s) need attention."
  echo "See docs/prerequisites.md for install commands."
  exit 1
fi

echo "Preflight passed."
