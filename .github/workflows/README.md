# CI

Three jobs, each protecting a specific claim:

| Job | Claim it protects |
|---|---|
| `core` | The pipeline is correct and the style is consistent. |
| `ffi` | The Rust/Swift boundary actually works — including the async tokio bridge, which is where FFI problems hide. Publishes the XCFramework as an artifact. |
| `windows` | The core is genuinely portable. Phase 4 is a UI project, not a rewrite. |

Phase 2 adds a fourth: the DictBench eval gate, which fails the build when a
prompt or model change regresses cleanup quality. See `docs/ARCHITECTURE.md`.
