# Process Wrapper Worker Design

## Overview

`process_wrapper` has two execution modes:

- Standalone mode executes one subprocess and forwards output.
- Persistent-worker mode speaks Bazel's JSON worker protocol and can keep
  pipelined Rust compilations alive across two worker requests.

The worker entrypoint is `worker::worker_main()`. It:

- reads one JSON `WorkRequest` per line from stdin
- classifies the request as non-pipelined, metadata, or full
- registers the request in `RequestCoordinator` before it becomes cancelable
- dispatches multiplex requests onto background threads via `RequestExecutor`
- serializes `WorkResponse` writes to stdout

## Request Kinds

Rust pipelining uses two request kinds keyed by `--pipelining-key=<key>`:

- Metadata request: starts rustc, waits until `.rmeta` is emitted, returns
  success early, and leaves the child running in the background.
- Full request: either takes ownership of the background rustc and waits for
  completion, or claims the key for a one-shot fallback compile.

Request classification must use the same rules in the main thread and the worker
thread. Relative `@paramfile` paths are resolved against the request's effective
execroot:

- `sandboxDir` when Bazel multiplex sandboxing is active
- the worker's current directory otherwise

This avoids the earlier split where pre-registration and execution could
disagree about whether a request was pipelined.

## Metadata Classes

Rust pipelining depends on an intermediate metadata artifact that lets downstream
crates start compiling before upstream codegen finishes. There are two distinct
classes of metadata artifact, with different portability and safety properties:

**Fast metadata** (`.rmeta`, `--emit=metadata`):
- Produced quickly by rustc as a compilation milestone
- Good for early checking and for pipelining within a single rustc process
- Not portable as the metadata input for a separate full-codegen invocation —
  if a non-deterministic proc macro produces different SVH values across two
  rustc processes, downstream consumers see E0463 or E0460
- Used by Cargo (single rustc per crate) and by worker pipelining in rules_rust

**Full metadata** (hollow `.rlib`, `--emit=link` with `-Zno-codegen`):
- A hollow rlib containing metadata but no object code
- Portable as input to downstream Rust codegen in a two-invocation graph
- The dependency graph is tier-consistent: hollow actions depend on upstream
  hollow rlibs, full actions depend on upstream full rlibs — so non-deterministic
  proc macros do not cause SVH mismatch
- Used by Buck2 (`metadata-full`) and by hollow-rlib pipelining in rules_rust

This distinction maps to pipelining modes:

| Mode | Metadata class | Artifact | Portable across strategies |
|------|---------------|----------|---------------------------|
| Worker pipelining | Fast metadata | `.rmeta` | No — requires same rustc process |
| Hollow-rlib pipelining | Full metadata | hollow `.rlib` | Yes — safe with any execution strategy |

Worker pipelining is Cargo-like: one rustc per crate, metadata and final artifact
from the same process, safety from process identity. Hollow-rlib pipelining is
Buck2-like: two rustc invocations per crate, a tier-consistent graph, safety from
graph structure.

For builds that may use sandboxed, remote, or dynamic execution — or any
configuration where the metadata and full actions might run as separate
processes — **hollow_rlib is the recommended portable mode**.

## Request Coordination and Invocation Lifecycle

`RequestCoordinator` (in `worker.rs`) tracks two data structures:

- `invocations`: pipeline key → `Arc<RustcInvocation>`
- `requests`: request id → optional pipeline key (presence means active; removal
  is the atomic claim — whoever removes the entry owns the right to send the
  `WorkResponse`)

Each `RustcInvocation` (in `worker_invocation.rs`) is a shared condvar-based
state machine with these states:

- `Pending`: invocation created but rustc not yet started
- `Running`: rustc child is alive, being driven by a background thread
- `MetadataReady`: `.rmeta` has been emitted; metadata handler can be unblocked
- `Completed`: rustc exited successfully; full handler can be unblocked
- `Failed`: rustc exited with non-zero code
- `ShuttingDown`: shutdown was requested; all waiters receive an error

The metadata handler spawns rustc, creates a `RustcInvocation` via
`spawn_pipelined_rustc`, and inserts it into the coordinator. The full handler
retrieves that shared invocation and calls `wait_for_completion`. If no
invocation exists yet, the full handler falls back to a standalone subprocess.

The critical invariant is that invocation insertion and retrieval happen under
the coordinator's mutex. The coordinator also arbitrates cancel/completion
races via the remove-on-claim pattern, ensuring only one response is sent per
request.

## Retry and Cancellation

Metadata retries use per-request output directories under:

`_pw_state/pipeline/<key>/outputs-<request_id>/`

This avoids deleting a shared `outputs/` directory before ownership of the key
has changed.

Cancellation is best-effort:

- non-pipelined requests only suppress duplicate responses via the remove-on-claim
  pattern on the `requests` map
- pipelined requests call `RustcInvocation::request_shutdown()`, which
  transitions to `ShuttingDown` and sends SIGTERM to the child process

The `requests` map serves as both the response-level guard and the lookup table.
Removal from the map is the atomic claim that prevents duplicate responses;
the optional pipeline key lets cancellation find the associated invocation.

## Sandbox Contract

When Bazel provides `sandboxDir`, the worker runs rustc with that directory as
its current working directory. Relative reads then stay rooted inside the
sandbox. Outputs that must survive across the metadata/full split are redirected
into `_pw_state/pipeline/<key>/...` and copied back into the sandbox before the
worker responds.

The worker also makes prior outputs writable before each request because Bazel
and the disk cache can leave action outputs read-only.

This satisfies the straightforward part of the multiplex-sandbox contract:
request-time reads and declared output writes stay rooted under `sandboxDir`.
The harder part is response lifetime: the metadata response returns before the
background rustc has finished codegen. The current safety argument is that rustc
has already consumed its inputs by `.rmeta` emission and that later codegen
writes go only into worker-owned `_pw_state`, but that depends on rustc
implementation details rather than on a Bazel-guaranteed contract. For that
reason, sandboxed worker pipelining should still be treated as
contract-sensitive, and the hollow-rlib path remains the compatibility fallback.

## Standalone Full-Action Behavior

Outside worker mode, a `--pipelining-full` action may be redundant. If the
metadata action already produced the final `.rlib` as a side effect and that
file still exists (unsandboxed local execution), standalone mode skips the
second rustc invocation and only performs the normal post-success actions
(`touch_file`, `copy_output`).

If the `.rlib` is missing — which happens under sandboxed, local, or remote
execution because the metadata action's separate rustc process does not produce
the undeclared `.rlib` side effect — the process wrapper warns and falls through
to run a second rustc. After rustc succeeds, it performs an SVH consistency
check: the full action injects `--emit=metadata=<temp>` to produce a standalone
`.rmeta`, then byte-compares it with the metadata action's `.rmeta` (passed via
`--pipelining-rmeta-path`). If they match, the crate's proc macros are
deterministic and the build proceeds. If they differ, a non-deterministic proc
macro produced different SVH values across the two rustc invocations, and the
build fails immediately with a diagnostic listing fix options (use worker
strategy, switch to hollow_rlib, or fix the proc macro).

This check catches the SVH mismatch at the source crate rather than producing
a cryptic E0463 in a downstream consumer. Under dynamic execution, the remote
leg fails fast, the local worker leg wins the race, and the build succeeds.

## Execution Strategy Compatibility

Three pipelining modes interact with Bazel's execution strategies. The matrix
below shows which combinations are supported.

### Execution requirements by mode

| Mode | `requires-worker-protocol` | `supports-multiplex-workers` | `supports-multiplex-sandboxing` |
|------|---|---|---|
| No pipelining | — | — | — |
| Hollow-rlib | — | — | — |
| Worker pipelining | `json` | `1` | `1` |

Hollow-rlib and no-pipelining actions are plain subprocesses with no worker
execution requirements (unless incremental compilation is separately enabled).
Worker-pipelining actions declare multiplex worker support and multiplex
sandboxing support.

### Compatibility matrix

```
                  local    sandboxed   worker   worker+mx-sandbox   dynamic    remote
No pipelining       ✓         ✓        n/a          n/a               ✓          ✓
Hollow-rlib         ✓         ✓        n/a          n/a               ✓          ✓
Worker pipeline     ✓*        ✓*        ✓           ✓                ✓¹         ✓*
```

\* **Deterministic proc macros only.** The full action runs a separate rustc
   process and checks SVH consistency afterward. If a non-deterministic proc
   macro produces different SVH values, the build fails immediately with a
   diagnostic (rather than a cryptic E0463 in a downstream consumer). Use
   worker strategy or switch to hollow_rlib for non-deterministic proc macros.

1. **dynamic + worker pipeline:** Bazel forces `mustSandbox=true` for dynamic
   execution. Because the action declares `supports-multiplex-sandboxing: 1`,
   the local leg runs as a **multiplex sandboxed worker** — the worker process
   is shared across requests but each request gets a `sandboxDir`. The remote
   leg runs process_wrapper as a one-shot standalone process (pipelining flags
   stripped). If the remote leg wins the race for a full action, it runs a
   second rustc with SVH checking — non-deterministic proc macros fail fast
   and the local worker leg wins the race.

### Why hollow-rlib shows n/a for worker

`_build_worker_exec_reqs()` with `use_worker_pipelining=False` (and no
incremental) returns an empty dict — no `supports-workers` or
`supports-multiplex-workers`. Bazel will not route these actions to a worker
process.

### Recommended configurations

| Use case | Settings | Metadata class |
|---|---|---|
| Portable builds (sandboxed, remote, dynamic, mixed) | `experimental_pipelined_compilation=hollow_rlib` | Full metadata |
| Maximum parallelism (local worker builds) | `experimental_pipelined_compilation=worker`, `--strategy=Rustc=worker` | Fast metadata |
| Dynamic execution | `experimental_pipelined_compilation=worker`, `--strategy=Rustc=dynamic`, `--experimental_worker_multiplex_sandboxing` | Fast metadata (local), standalone fallback (remote) |

**hollow_rlib is the safe default for any build that may run outside a persistent
worker.** It uses full metadata (tier-consistent graph) and is compatible with all
execution strategies. Worker pipelining uses fast metadata and achieves higher
parallelism but requires worker execution to guarantee single-process safety.

## Determinism Contract

Bazel persistent workers are expected to produce the same outputs as standalone
execution. For Rust pipelining this becomes a hard requirement under dynamic
execution: a local worker leg and a remote standalone leg may race, so the
resulting `.rlib` and `.rmeta` artifacts must be byte-for-byte identical.

> "The invariant, however, is that strategies do _not_ affect the semantics of
> the execution: that is, running the same command line on strategy A and
> strategy B must yield the same output files."
> — Julio Merino, [What are Bazel's strategies?](https://jmmv.dev/2019/12/bazel-strategies.html)

There are two relevant worker paths:

- Non-pipelined requests re-exec `process_wrapper` via `run_request()`, so they
  share the standalone path by construction.
- Pipelined requests diverge: `RequestExecutor::execute_metadata()` spawns
  rustc directly, rewrites output locations into `_pw_state`, and
  `RequestExecutor::execute_full()` later joins that background compile and
  materializes artifacts.

That second path is where determinism matters most. The same rustc flags used by
the worker must be preserved in standalone comparisons, including
`--error-format=json` and `--json=artifacts`, because those flags affect the
metadata rustc emits and therefore the crate hash embedded in downstream-facing
artifacts.

### Strategy-Equivalence Unification

Both pipelining modes (hollow-rlib and worker) must produce equivalent
rustc-visible behavior so that switching between them — or switching execution
strategies within worker-pipelining mode — does not change the output.

The following properties are unified across modes:

- **`RUSTC_BOOTSTRAP=1`**: set on **every** Rustc action (rlibs, binaries,
  tests, proc-macros) when any pipelining mode is active. 
  `RUSTC_BOOTSTRAP` changes the crate SVH; a binary compiled
  without it cannot load rlibs compiled with it (E0463). 
- **`--cfg=rules_rust_pipelined`**: set on every Rustc action when pipelining
  is active. Distinguishes pipelining-enabled from pipelining-disabled builds
  in the action cache so cached artifacts are not reused across modes. The two
  pipelining modes (hollow-rlib and worker) already differ in `--emit` flags
  and declared outputs, so their cache keys are naturally distinct from each
  other.
- **Mnemonic `"Rustc"`**: all pipelining metadata actions use mnemonic `"Rustc"`
  (not `"RustcMetadata"`). This ensures Bazel treats all pipelining rustc
  actions equivalently for strategy selection.

Irreducible differences that remain (format-driven, not behavioral):

- `--emit` shape: `--emit=link=<hollow.rlib>` vs `--emit=metadata=<path>,link`
- `-Zno-codegen`: only on hollow-rlib metadata action
- `--pipelining-*` protocol flags: only on worker-pipelining actions (stripped
  before rustc sees them)
- Env delivery: worker-pipelining uses `.worker_env` files for worker-key
  sharing; hollow-rlib uses direct action env. Both deliver the same vars to
  the rustc child process.

The design principle enforced here:

1. Outside worker mode, a worker-pipelining action should emulate the worker
   result with one combined rustc invocation that matches the worker
   rustc-visible behavior as closely as possible.
2. If the .rlib side-effect is not available, warn and fall through to a second
   rustc. Users with non-deterministic proc macros should use hollow-rlib mode,
   whose tier-consistent graph (hollow→hollow, full→full) avoids SVH mismatch.

## Determinism Test Strategy

`process_wrapper_test` uses the real toolchain rustc from Bazel runfiles
(`RUSTC_RLOCATIONPATH`) together with `current_rust_stdlib_files`, so the test
compares the worker against the production compiler instead of a fake binary.

The test harness relies on a few implementation hooks:

- `run_standalone(&Options)` factors the standalone execution path out of
  `main()` so tests can invoke it without exiting the process.
- Worker submodules (`pipeline`, `args`, `exec`, `sandbox`, `invocation`,
  `rustc_driver`, `protocol`, `types`, `logging`, `request`) are `pub(crate)`
  so unit tests can drive the pipelined handlers directly.
- `RUST_TEST_THREADS=1` is set for `process_wrapper_test` because cache-seeding
  tests temporarily change the process current working directory.

**TODO:** A byte-for-byte determinism regression test (`test_pipelined_matches_standalone`)
is planned but not yet implemented. The intended approach:

1. compile a trivial crate twice with standalone rustc to prove the baseline is
   itself deterministic for the chosen flags
2. run the same crate through `execute_metadata()` and `execute_full()`
3. compare both `.rlib` and `.rmeta` bytes between standalone and worker

The `.rmeta` comparison is as important as the `.rlib` comparison because
downstream crates compile against metadata first; a metadata mismatch can expose
different SVH or type information even if the final archive happens to link.

## Regression Test Coverage

`worker_pipelining_nondeterministic_test.sh` exercises the actual failure
boundary around non-deterministic proc macros across all pipelining modes:

| Phase | Mode | Execution | Metadata class | Expected |
|-------|------|-----------|---------------|----------|
| 1 | Worker pipelining | Worker | Fast metadata | PASS (single rustc) |
| 2 | No pipelining | Local | — | PASS (baseline) |
| 3 | Hollow-rlib | Local | Full metadata | PASS (tier-consistent) |
| 4 | Worker pipelining | Sandboxed | Fast metadata | FAIL (SVH mismatch) |

Phase 4 verifies that the process_wrapper SVH consistency check catches the
mismatch and produces a clear diagnostic. The practical error symptoms include:

- `E0460`: crate found with incompatible SVH (downstream consumer gets the
  wrong version hash from the metadata action's `.rmeta` vs the full `.rlib`)
- `E0463`: can't find crate (rustc cannot match the SVH at all and treats the
  crate as missing)

Both errors are valid manifestations of the same root cause: the fast metadata
`.rmeta` from one rustc invocation has a different SVH than the full `.rlib`
from a separate invocation when a non-deterministic proc macro is involved.

## Artifact Hash Instrumentation

`artifact_hash_check.sh` in `test/unit/pipelined_compilation/` provides
manual instrumentation for investigating SVH consistency. It computes
SHA-256 hashes for three artifact types:

1. **Declared metadata artifact** — the hollow `.rlib` (hollow_rlib mode) or
   `.rmeta` (worker mode) that downstream metadata actions consume
2. **Full `.rlib`** — the final archive that downstream full actions consume
3. **Embedded `lib.rmeta`** — the metadata section extracted from the full
   `.rlib` via `ar x`

This instrumentation is useful for:

- Validating that a rustc version change has not broken SVH compatibility
- Comparing artifacts across pipelining modes or execution strategies
- Investigating whether a specific proc macro is deterministic
- Future rustc experiments (e.g., testing a hypothetical stable `-Zno-codegen`
  replacement or a first-class "full `.rmeta`" output mode)

The script is tagged `manual` and is not part of the automated test suite.

## Module Structure

The worker code is organized into single-responsibility modules:

| Module | File | Responsibility |
|--------|------|---------------|
| `types` | `worker_types.rs` | Domain newtypes: `PipelineKey`, `RequestId`, `SandboxDir`, `OutputDir` |
| `protocol` | `worker_protocol.rs` | Bazel JSON wire protocol: parse `WorkRequest`, build `WorkResponse` |
| `args` | `worker_args.rs` | Arg parsing, expansion, rewriting, env building |
| `pipeline` | `worker_pipeline.rs` | Pipeline directory lifecycle, output materialization, `PipelineContext` |
| `exec` | `worker_exec.rs` | Subprocess spawning, file utilities, permissions, process kill helpers |
| `sandbox` | `worker_sandbox.rs` | Sandbox-specific: cache seeding, sandboxed copies, sandboxed execution |
| `invocation` | `worker_invocation.rs` | `RustcInvocation` state machine (condvar-based concurrent lifecycle) |
| `rustc_driver` | `worker_rustc.rs` | Rustc child process management: `spawn_pipelined_rustc`, `spawn_non_pipelined_rustc` |
| `request` | `worker_request.rs` | `RequestExecutor`, `RequestKind`: dispatch to metadata/full/fallback/non-pipelined paths |
| `logging` | `worker_logging.rs` | Structured lifecycle logging, `WorkerLifecycleGuard` |

Current coverage splits across layers:

- no pipelining: covered by unit tests exercising standalone options and rustc
  invocation
- hollow-rlib pipelining: covered by analysis tests that verify consistent flag
  selection
- worker pipelining: covered by unit tests for protocol, args, sandbox, and
  invocation state machine; end-to-end coverage via reactor-repo builds

## Historical Notes

The following conclusions came from the older `thoughts/` design notes and are
worth keeping even though the plan file itself is gone:

- Stable worker keys were a prerequisite, not a detail. Metadata and full
  requests only share one worker process and one in-process pipeline state if
  request-specific process-wrapper flags are moved out of startup args and into
  per-request files.
- The staged-execroot and stage-pool family was explored and rejected. Measured
  reuse stayed too low to justify the extra machinery; the meaningful win came
  from early `.rmeta` availability, not from worker-side restaging.
- Cross-process shared stage pools were rejected for the same reason: they add
  leasing and invalidation complexity without addressing the main bottleneck.
- "Resolve through the real execroot" is not the current sandbox design. It did
  reduce worker-side staging cost, but it violates the documented `sandboxDir`
  contract and should not be treated as the supported direction.
- The alias-root strict-sandbox idea was explored but not landed. It had useful
  investigative value, especially around post-`.rmeta` rustc behavior, but it
  would require a larger rewrite and stronger validation than the current
  branch justified.
- Broad metadata-input pruning was investigated and rejected after real
  `E0463` missing-crate regressions. Any future pruning has to be trace-driven
  and validated against full dependency graphs.
- Teardown and shutdown behavior deserves explicit skepticism. Earlier
  investigations saw multiplex-worker cleanup trouble around `bazel clean`, so
  worker shutdown and cancellation behavior should continue to be validated as a
  first-class part of the design.

To avoid stale guidance, the following should be treated as explicitly not
current on this branch:

- staged execroot reuse as the active architecture
- cross-process stage pools as the preferred next step
- resolve-through reads outside `sandboxDir` as the supported sandbox story
- alias-root (`__rr`) as an implemented or imminent design

## Open Questions

The implementation is substantially more complete than the old plan, but a few
design questions remain open:

- If strict post-response sandbox compliance is required, should sandboxed and
  dynamic modes fall back to the hollow-rlib two-invocation path, or should a
  different strict-sandbox design replace the current one-rustc handoff?
- How much teardown and cancellation validation is enough to treat the
  background-rustc lifetime as operationally solid under `bazel clean`,
  cancellation races, and dynamic execution?
- Diagnostics processing now runs on the monitor thread rather than the request
  thread. Verify the output format still satisfies Bazel consumers.
- Windows `#[cfg(windows)]` paths in `execute_metadata` are preserved but
  untested under the new invocation architecture.
- Small timing window: `.rmeta` exists in the pipeline output directory before
  it is copied to the declared output location. Verify Bazel's output checker
  does not race with this copy.
