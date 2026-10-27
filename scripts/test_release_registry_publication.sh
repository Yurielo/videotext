#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/scripts/release_gate.sh"

grep -Fq -- '--owner-pass-reference' "$GATE"
grep -Fq -- 'record-delivery' "$GATE"
grep -Fq -- 'registry_integration.py" publish' "$GATE"
grep -Fq -- 'merge-base --is-ancestor "$SOURCE_COMMIT" refs/remotes/origin/main' "$GATE"

smoke_line="$(grep -n -F 'post_install_smoke_status PASS' "$GATE" | cut -d: -f1 | head -1)"
delivery_line="$(grep -n -F 'record-delivery' "$GATE" | cut -d: -f1 | head -1)"
publish_line="$(grep -n -F 'registry_integration.py" publish' "$GATE" | cut -d: -f1 | head -1)"
[[ -n "$smoke_line" && -n "$delivery_line" && -n "$publish_line" ]]
(( smoke_line < delivery_line && delivery_line < publish_line ))

printf 'RELEASE_REGISTRY_PUBLICATION_CONTRACT_PASS\n'
