# VideoText registry integration — verified authority and release boundary

Issue #51 / PR #52. This task prepares a new VideoText release and its future
registry publication; it does not authorize installation or activation before
exact Candidate Owner acceptance.

| Binding source | Resolved commit | Document SHA-256 |
| --- | --- | --- |
| Integra unified rules | `9c39583c9be328fc2b4f98992f0d92e6e471fc2c` | `8b8e31c7620d45e1e14429e07e7b97b2adc118745ce781a55b932213c55b646b` |
| Central registry `AGENTS.md` | `226768180bbb217485c7d5ec53d360d8ebcb4615` | `d97fff57c37671d4f904f04e9723f06c7364e911aff534b58ec1ca8bea5da536` |
| Central architecture | same central commit | `61a49437994bd481d9be71bd26a7d24bfff77ae9e04abddf127e9c4c1fcbc9a0` |
| VideoText `AGENTS.md` | `c3a4424a1deee42598bab8cf4ba70b43fcaf7e91` | `57200d50eaca5389267d63a248fbfae56213ecc1e314987020a9019726987d01` |
| VideoText release gate | same VideoText commit | `79ece3bb3017ca2450e6bc17c740fb70645129055bfae3dcc6c3a644ed9b4869` |

## Current registry state

Central `seminartext.current` is activation
`sha256:ab55491793b6207ae0bfd4c61e1872f5104d9e70e6d016fc98b2b22bc619ba91`.
Its verified native proof identifies SeminarText source
`9c99028ea15388a3850770c7cfe6c816406c4335` and 36 components. The CLI
digest is `97bcbb2c7d9c6936c8fbe8efa1f5ad0b78e807eb7cea73b0f5a7b7f484889bd1`.
Current VideoText activation is 0.7.0, central generation 3, event
`sha256:0e56e700a7432fe6eeff88fd379cd9ac1ee78a7543029494cc6fb9672e6fc0d2`.
It already pins this SeminarText source. The prior analysis describing an
unregistered provider and VideoText 0.6.8 is historical and no longer a release
gate premise.

## Boundary checks

The tracked `Resources/SeminarText` cannot supply the registered 36-component
inventory: preparation stops at absent `SEMINARTEXT_4_ROADMAP.md`. An archive of
the exact registered source commit passes all 36 SHA-256 checks. A real release
must explicitly supply that material root; a missing or mismatched component
never falls back to an installed provider or stale bundle.

The PR's original `release_gate.sh --promote` publication wiring could rebuild
the exact Candidate already accepted by the Owner. That is incompatible with
the retained Candidate identity required by `docs/RELEASE_GATE.md`. Registry
publication is now a separate completion step after the native post-owner
delivery receipt. It verifies the pre-owner release record, accepted Candidate,
Owner PASS receipt, merge ancestry, installed app, embedded provider manifest,
codesign and post-install lifecycle. It neither rebuilds nor installs.

The adapter uses the central publisher and immutable outbox. Publication
failure leaves the delivered product intact and supports retry. A later
SeminarText activation does not invalidate the historical pinned dependency;
central dependency status reports update need without changing the pin.

No real central registry event or installed application was changed while
preparing this integration.
