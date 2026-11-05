#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/scripts/release_gate.sh"
DELIVERY="$ROOT/scripts/complete_registry_delivery.sh"

grep -Fq -- 'seminartext_dependency_manifest' "$GATE"
grep -Fq -- 'candidate_seminartext_sha256' "$GATE"
grep -Fq -- '--native-delivery' "$DELIVERY"
grep -Fq -- 'record-delivery' "$DELIVERY"
grep -Fq -- 'registry_integration.py" publish' "$DELIVERY"
if grep -Fq -- 'registry_integration.py" publish' "$GATE"; then
  echo 'Release gate must not publish a rebuilt promotion as accepted delivery' >&2
  exit 1
fi

printf 'RELEASE_REGISTRY_PUBLICATION_CONTRACT_PASS\n'
