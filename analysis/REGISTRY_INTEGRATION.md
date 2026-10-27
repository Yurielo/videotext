# VideoText registry integration — authority and current boundary

Task authority: **Four-Product Architecture — VideoText Registry Integration**.
This bounded task authorizes the adapter and its verification, not a VideoText
build, Owner acceptance, installation, activation or synthetic central event.

| Binding source | Exact commit | SHA-256 |
| --- | --- | --- |
| Integra unified rules | `86e0801963e85e8d8b121c569fe624bb64ede5df` | `8b8e31c7620d45e1e14429e07e7b97b2adc118745ce781a55b932213c55b646b` |
| Central registry `AGENTS.md` | `66c6a5128922f65c1993b59f5ba38923683aeb1e` | `d97fff57c37671d4f904f04e9723f06c7364e911aff534b58ec1ca8bea5da536` |
| Central architecture | same central commit | `61a49437994bd481d9be71bd26a7d24bfff77ae9e04abddf127e9c4c1fcbc9a0` |
| Central publication contract | same central commit | `cc50ac0a524370678bf0115d65b9dc6de24972ea624f191963e7c267a20f4b2b` |
| VideoText `AGENTS.md` | `814c2aeab4eb76cd345c484575507ac73da11784` | `57200d50eaca5389267d63a248fbfae56213ecc1e314987020a9019726987d01` |
| VideoText release gate | same VideoText commit | `79ece3bb3017ca2450e6bc17c740fb70645129055bfae3dcc6c3a644ed9b4869` |

## Reconciled state

Central validation at `66c6a5128922f65c1993b59f5ba38923683aeb1e` is VALID
with two historical events: VideoText `0.6.8` and BookText `0.1.0`. VideoText
current event is `sha256:60f3c037c659f5386cafdc0cf9c51350e28bb5ba5f7ac0ff3fa6eedfc9aa840f`.
Its retained embedded SeminarText source is
`cf7a8445fa9f9dffc62b7ae24062e80475a3d223`. This is historical provenance,
not a substitute for a current provider release.

`seminartext.current` remains null with its retained reason: a complete native
post-deploy success receipt has not been established. Consequently, central
status reports `PROVIDER_UNREGISTERED` for VideoText's actual old dependency.

The VideoText source checkout used for implementation is the clean canonical
main `814c2aeab4eb76cd345c484575507ac73da11784`, obtained from the verified
GitHub repository. The pre-existing `Documents/videotext` directory was an
unrelated empty Git skeleton without an origin or commit and was not changed.

## Adapter boundary

The adapter imports the existing central `registry.py`; it does not copy its
schema, validation, event identity, append-only logic or Git CAS publisher.
Future preparation resolves central remote main and requires the exact current
SeminarText event plus successful bound native receipt. It validates every
retained component/artifact against supplied material before bundling and makes
the resulting manifest part of candidate evidence. Build/E2E then revalidate
the prepared bundle against central current state. There is no fallback to the
tracked historical bundle, a standalone installation, or repository HEAD.

VideoText publication is now wired into the existing `--promote` lifecycle,
after a required immutable Owner PASS URL, final gate, confirmed merge on
`origin/main`, exact installation and passing post-install smoke. The adapter's
delivery receipt records those completed facts deterministically and the
central publisher atomically retains native evidence/event/current. A failed
publication leaves delivery unchanged with its exact outbox retained for retry.
Newer same-product history and altered retained data are rejected by the
central publisher; an unprepared current provider blocks new publication rather
than rewriting a dependency.

No real registry history, installed VideoText app, SeminarText installation,
Candidate, Owner decision or release input was altered during this task.
