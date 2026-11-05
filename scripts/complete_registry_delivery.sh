#!/usr/bin/env bash
# Complete central publication only after the existing native post-owner delivery.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY_ROOT="${VIDEOTEXT_REGISTRY_ROOT:-$ROOT/../four-product-architecture}"
REGISTRY_PYTHON="${VIDEOTEXT_REGISTRY_PYTHON:-$REGISTRY_ROOT/.venv/bin/python}"

if [[ $# -ne 5 ]]; then
  echo "Usage: $0 <pre-owner release.env> <post-owner-delivery.json> <Owner PASS HTTPS URL> <installed videotext.app> <retained outbox directory>" >&2
  exit 2
fi
RELEASE_EVIDENCE="$1"
NATIVE_DELIVERY="$2"
OWNER_PASS_REFERENCE="$3"
INSTALLED_APP="$4"
OUTBOX="$5"
[[ -x "$REGISTRY_PYTHON" ]] || { echo "Central registry Python unavailable" >&2; exit 2; }
[[ "$OWNER_PASS_REFERENCE" == https://* ]] || { echo "Immutable Owner PASS URL required" >&2; exit 2; }
mkdir -p "$OUTBOX"
RECEIPT="$OUTBOX/delivery-receipt.json"

"$REGISTRY_PYTHON" "$ROOT/scripts/registry_integration.py" record-delivery \
  --root "$ROOT" --registry-root "$REGISTRY_ROOT" \
  --release-evidence "$RELEASE_EVIDENCE" --native-delivery "$NATIVE_DELIVERY" \
  --owner-pass-reference "$OWNER_PASS_REFERENCE" --installed-app "$INSTALLED_APP" \
  --output "$RECEIPT"
"$REGISTRY_PYTHON" "$ROOT/scripts/registry_integration.py" publish \
  --registry-root "$REGISTRY_ROOT" --receipt "$RECEIPT" --outbox "$OUTBOX"
