# Architecture Decision Records

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | accepted |
| [0002](0002-configurable-keys-and-table-names.md) | Storage keys and table names are host-configurable at compile time (UXID default, `statifier_` prefix, runs vocabulary); engine identities are not | accepted |
| [0003](0003-storage-adapter-behaviour-and-the-identity-guard.md) | The storage adapter stores opaque blobs keyed by engine identities; the identity guard lives above every adapter and cannot be skipped | accepted |
| [0004](0004-run-lifecycle-executor-seam-and-serialization.md) | The run record owns its position, the loop's order is the contract, effects cross a host-executor seam (failures re-enter as `error.communication`), and per-run serialization is a pluggable strategy | accepted |
| [0005](0005-ecto-in-package-and-postgres-test-harness.md) | The Ecto layer ships in this package behind optional `ecto_sql`; the test harness is a real Postgres server with the SQL sandbox, no skip tag | accepted |
| [0006](0006-optional-opaque-run-metadata.md) | Runs carry an optional opaque `metadata` map of host identities (never personal data); an adapter that cannot store it refuses at open with `{:error, :metadata_unsupported}`, and the Ecto adapter stores jsonb with an equality-match list helper | accepted |
| [0007](0007-async-invocation-seam.md) | A durable run can rest mid-invocation: a `:pending` dispatch arm, two public completion doors, and persisted `active_invocations` as the cancel-versus-completion race mechanism | accepted |
| [0008](0008-durable-subchart-child-runs.md) | A durable subchart's child is an ordinary run, linked by reserved metadata carrying a mandatory chart-identity pin, started as a `:pending` dispatch and answered through ADR-0007's doors, and ended by a cascading cancel that retains; nesting is bounded by the resolver's cycle refusal and fan-out is designed for, not built | proposed |

New ADRs: next number, same three-section format (Context, Decision,
Consequences). Pick the number against a freshly fetched remote. A bare
`ADR-NNNN` cites this repository's own records; a cross-repo citation
carries the owning repo's beads prefix (`st-ADR-0052` is statifier-ex's
ADR-0052).
