# Four-Product Registry integration

VideoText bundles SeminarText. The authoritative central activation identifies
the provider release; a repository HEAD or an older local bundle cannot replace
that identity.

## Verified build input

`scripts/registry_integration.py resolve` validates central `main` and its
current SeminarText event, native activation proof, source commit and component
inventory. `prepare` copies every component from a material root only when its
SHA-256 matches the registered receipt. It writes a bound dependency manifest.

The currently registered SeminarText source is
`9c99028ea15388a3850770c7cfe6c816406c4335` with 36 components. Supply a
clean archive of that exact commit as `VIDEOTEXT_SEMINARTEXT_MATERIAL_ROOT` for
the release gate. The default `Resources/SeminarText` is incomplete for this
activation and correctly fails closed. No installed product is used as an
implicit source or modified during preparation.

```sh
CENTRAL=/exact/four-product-architecture
export VIDEOTEXT_REGISTRY_ROOT="$CENTRAL"
export VIDEOTEXT_REGISTRY_PYTHON="$CENTRAL/.venv/bin/python"
export VIDEOTEXT_SEMINARTEXT_MATERIAL_ROOT=/exact/registered-seminartext-source
scripts/release_gate.sh --profile core /exact/short-video.mp4 /exact/model.bin
```

`build_app.sh` and `test_e2e.sh` re-resolve current central state and reject an
absent, incomplete or stale prepared bundle before changing an app target.
Both E2E executions and the Candidate build use the same verified preparation.
The release evidence records the activation event and manifest hash. The clean
hosted macOS packaging check resolves the real current central activation and
checks out that exact SeminarText source commit into a disposable runner path.
It logs `QUALIFIED_PROVIDER_ACTIVATION` and `QUALIFIED_PROVIDER_SOURCE`; compare
both to the retained Candidate manifest before recording the CI/CD verdict.
An intervening provider activation requires requalification. The workflow
performs no central publication or product installation.

## Publication after native delivery

The existing lifecycle is:

`Owner PASS → final gate → merge → install exact Candidate → post-install smoke → DELIVERED`.

After native delivery, `complete_registry_delivery.sh` checks the retained
pre-owner release evidence, immutable Owner PASS receipt, native post-owner
delivery receipt, accepted Candidate, installed bytes, bundled SeminarText
inventory, source ancestry, version and lifecycle. It then records an immutable
delivery receipt and publishes with the existing central `registry.py` publisher.
It does not build, sign, install or launch VideoText.

```sh
scripts/complete_registry_delivery.sh \
  /exact/pre-owner/evidence.env \
  /exact/post-owner-delivery.json \
  https://github.com/Yurielo/videotext/issues/NN#issuecomment-NN \
  /Users/yurielokhin/Applications/videotext.app \
  /exact/retained/registry-publication
```

`release_gate.sh --promote` rebuilds its Candidate and therefore is not the
publication path for the exact Candidate already accepted by the Owner.
Publication does not run for a build, Candidate, merge or installation alone.
If central publication fails, native delivery and the exact outbox remain
intact; rerun the same command to retry. An intervening provider activation
does not rewrite the delivered VideoText dependency pin. The central registry
reports that provider relationship as `UPDATE_REQUIRED` when appropriate.

At this integration check, central `seminartext.current` is event
`sha256:ab55491793b6207ae0bfd4c61e1872f5104d9e70e6d016fc98b2b22bc619ba91`.
The current VideoText activation is 0.7.0 and already pins the same SeminarText
source. A new VideoText activation still requires its own qualified Candidate,
Owner PASS and native delivery.
