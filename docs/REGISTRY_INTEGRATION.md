# Four-Product Registry integration

VideoText bundles SeminarText. It never treats the installed standalone
SeminarText application, a repository head, or an older source bundle as a
substitute for a centrally activated provider release.

## Preparation for a future build

The central registry is the sole source of the current SeminarText activation.
`scripts/registry_integration.py resolve` fetches and validates central `main`,
then requires the current SeminarText event, its retained successful native
activation proof, its source commit, release identity and every artifact.

For a real build, provide a directory containing the exact registered source
material, laid out by the component `repository_path` values retained in that
activation receipt. The command copies only those checked files and writes a
bound manifest:

```sh
CENTRAL=/exact/four-product-architecture
CENTRAL_PYTHON="$CENTRAL/.venv/bin/python"
"$CENTRAL_PYTHON" scripts/registry_integration.py prepare \
  --registry-root "$CENTRAL" \
  --material-root /exact/registered-seminartext-material \
  --output /private/tmp/videotext-seminartext-prepared
export VIDEOTEXT_SEMINARTEXT_PREPARED=/private/tmp/videotext-seminartext-prepared
scripts/build_app.sh
```

`build_app.sh` and `test_e2e.sh` reject absent or incomplete preparation. They
also re-resolve central `main` and verify that the prepared manifest still
matches its current SeminarText event. They do not copy `Resources/SeminarText`
as a fallback. The release gate prepares
one bundle before its checks, passes that exact bundle to both E2E executions
and candidate build, and retains the activation event and manifest hash in its
existing evidence. It defaults material input to `Resources/SeminarText`, which
is safe because hash mismatch is a hard failure; a future release normally sets
`VIDEOTEXT_SEMINARTEXT_MATERIAL_ROOT` to verified material for the registered
provider event.

This changes future preparation only. It does not modify any existing VideoText
application, replace its bundled SeminarText, run a product E2E, or claim that
the existing VideoText activation uses a newer provider.

## VideoText publication after delivery

The current delivery chain remains exactly:

`Owner PASS → Final Gate → Merge → install exact Candidate → post-install smoke → DELIVERED`.

On the `--promote` path, `release_gate.sh` requires the existing immutable
Owner PASS URL. It verifies that the approved source is already merged on
`origin/main`, installs the exact candidate, runs its post-install smoke, then
records and publishes the native delivery fact through the existing central
publisher. These adapter commands are evidence and publication steps; they do
not grant Owner PASS, installation, or delivery authority.

```sh
scripts/release_gate.sh --profile core /exact/short-video.mp4 /exact/model.bin \
  --promote \
  --owner-pass-reference https://github.com/Yurielo/videotext/issues/NN#issuecomment-NN
```

The receipt requires a promoted PASS evidence record, same candidate/final
digest, post-install smoke PASS, merged source commit, exact installed bundle
digest, an immutable Owner PASS reference, and the retained SeminarText
dependency manifest. Publication retains immutable event/proof bytes, calls the
central `registry.py publish` function, and stores a read-back confirmation.
Failure leaves native delivery intact and evidence retryable. Retry uses the
same receipt/outbox; it may never re-seal a later SeminarText or VideoText
event. A newer SeminarText event after delivery rejects publication: prepare a
new consumer release through its normal lifecycle.

The adapter's `record-delivery` and `publish` subcommands remain the only
recovery path for an interrupted publication, using the exact retained release
evidence, receipt and outbox from that delivery. They are not a replacement for
the gate's normal lifecycle integration.

The delivery gate does not publish on build, candidate creation, source merge,
or installation alone. Central rollback remains a new verified native activation
record under the existing central rollback contract.

## Present prerequisite

At the time this adapter was added, central `seminartext.current` is null. The
adapter therefore rejects production preparation before any VideoText build or
E2E. This is expected, and no synthetic activation is permitted in the real
registry. Existing VideoText 0.6.8 remains registered with its historical
embedded SeminarText source `cf7a8445fa9f9dffc62b7ae24062e80475a3d223`.
