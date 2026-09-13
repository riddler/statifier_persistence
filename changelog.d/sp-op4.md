### Changed

- **Breaking for storage adapters.** `run` is retired as the noun for the
  durable record; it is `execution` everywhere (ADR-0011). Nothing about the
  behaviour, the arities, the return shapes or the identity guard changed -
  only names. This entry is the complete list of what moved. Rename the seven
  `StatifierPersistence.Storage.Adapter` callbacks below in your adapter; the
  compiler names every one of them, and no compatibility shim, deprecated
  delegate or alias module ships.

  | Callback before | After |
  |---|---|
  | `insert_run/2` | `insert_execution/2` |
  | `fetch_run/2` | `fetch_execution/2` |
  | `update_run/2` | `update_execution/2` |
  | `lock_run/3` | `lock_execution/3` |
  | `list_runs_by_metadata/2` | `list_executions_by_metadata/2` |
  | `supports_run_outcome?/1` | `supports_execution_outcome?/1` |
  | `list_run_states_by_metadata/2` | `list_execution_states_by_metadata/2` |

  `append_input/3` and `list_inputs/2` keep their names; their `run_id()`
  parameter is now `execution_id()`.

- **Breaking for a host-supplied serialization strategy.** The second
  behaviour a host may implement renames its one callback:
  `StatifierPersistence.Serialization.with_run/3` is now `with_execution/3`,
  and the shipped `Serialization.AdapterLock.with_run/3` is now
  `AdapterLock.with_execution/3`. A host that left the strategy at its default
  implements nothing and is unaffected. The two module names are unchanged -
  they name a strategy, not the durable record.

- **Breaking, silently, for a host effect executor and a `:dispatch`
  function.** The `run_id:` key of `StatifierPersistence.Executor.context/0`
  and of `StatifierPersistence.Driver.dispatch_context/0` is now
  `execution_id:`. An implementation that pattern-matches `%{run_id: id}`
  raises at the first effect; one that reads the key by name gets `nil`.
  Rename the key in both.

- **Breaking for a host that pattern-matches this package's error atoms.**
  `:run_exists`, `:run_not_found`, `:run_outcome_unsupported`,
  `:run_states_unsupported`, `:run_position_missing` are now
  `:execution_exists`, `:execution_not_found`,
  `:execution_outcome_unsupported`, `:execution_states_unsupported`,
  `:execution_position_missing`. A `case` with no catch-all raises; one with a
  catch-all quietly reclassifies a known refusal.

- **Breaking for anything subscribed to this package's telemetry.** The event
  family is now `[:statifier_persistence, :execution, :step, :start | :stop]`,
  `[:statifier_persistence, :execution, :lock]` and
  `[:statifier_persistence, :execution, :created | :terminated | :discarded]`.
  There is no dual emit: a handler attached to the old `:run` names goes
  silent with no error, so grep your handlers for the old prefix as part of
  the upgrade. `opentelemetry_statifier` 0.6.0 moves in lockstep.

- Telemetry metadata keys `run_id`, `parent_run_id` and `child_run_id` are now
  `execution_id`, `parent_execution_id` and `child_execution_id` on every
  event that carries them, including the events whose own names did not
  change (`[:statifier_persistence, :adapter, :call]`, `:identity, :refused`,
  `:effect, :failed`, `:drive, :turns_exhausted` and the six
  `[:statifier_persistence, :child, ...]` events).

- Two documented telemetry metadata *values* rename with them: `stage: :run`
  becomes `stage: :execution` on `[:statifier_persistence, :identity,
  :refused]`, and `reason: :terminal_run` becomes `reason:
  :terminal_execution` on `[:statifier_persistence, :execution, :discarded]`.

- The six documented `StatifierPersistence.Telemetry` emitters rename with
  their events: `run_step_start/3`, `run_step_stop/2`, `run_lock/2`,
  `run_created/1`, `run_terminated/1` and `run_discarded/1` are now
  `execution_step_start/3`, `execution_step_stop/2`, `execution_lock/2`,
  `execution_created/1`, `execution_terminated/1` and
  `execution_discarded/1`. The other ten emitters keep their names.

- Modules: `StatifierPersistence.Run` is now `StatifierPersistence.Execution`
  (struct field `:run_id` is now `:execution_id`), `StatifierPersistence.Runs`
  is now `StatifierPersistence.Executions`, and
  `StatifierPersistence.Run.Linkage` is now
  `StatifierPersistence.Execution.Linkage`, whose `child_run_id/3` is now
  `child_execution_id/3`. The lifecycle doors keep their own names and
  arities: `Executions.create/4`, `step/5`, `fail/4`, `cancel/3`,
  `cascade_cancel/3` and `inputs/2`.

- `StatifierPersistence.Storage` renames nine functions, arities unchanged:
  `insert_run/5`, `update_run/5`, `update_run_status/4`, `fetch_run/2`,
  `run_outcome_supported?/1`, `run_states_supported?/1`,
  `list_run_states_by_metadata/2`, `list_runs_by_metadata/2` and
  `load_run_position/3` become `insert_execution/5`, `update_execution/5`,
  `update_execution_status/4`, `fetch_execution/2`,
  `execution_outcome_supported?/1`, `execution_states_supported?/1`,
  `list_execution_states_by_metadata/2`, `list_executions_by_metadata/2` and
  `load_execution_position/3`.

- Types: `Storage.Adapter.run_id/0`, `run_status/0`, `run_record/0` and
  `run_state/0` are now `execution_id/0`, `execution_status/0`,
  `execution_record/0` and `execution_state/0`, and the `run_id:` key inside
  `execution_record/0`, `execution_state/0`, `input_record/0` and
  `Storage.input/0` is now `execution_id:`. `Runs.run_id/0` is now
  `Executions.execution_id/0`, and `Storage.run_write_opt/0` is now
  `Storage.execution_write_opt/0`.

- The reserved child-linkage metadata key written into a child's `metadata`
  map is now `"parent_execution_id"`, and `Execution.Linkage`'s struct field
  is `:parent_execution_id`. A child written by 0.11.x carries the old key;
  re-key it or let those executions finish under 0.11.x.

- `use StatifierPersistence.Ecto` now generates `MyApp.Persistence.Execution`
  instead of `MyApp.Persistence.Run`, and the executions and inputs schemas
  expose the field as `execution_id` instead of `run_id`. A host naming the
  module or the field in its own queries renames both.

- New surrogate ids for that table carry the `exec_` prefix instead of
  `run_`. Existing rows keep the ids they have - nothing rewrites them - so
  both spellings coexist permanently on an upgraded install. Nothing in this
  package parses a prefix and no host should; one that does must accept both.

- The reserved `<donedata>` key a chart writes to fail itself is now
  `statifier_persistence:execution_status`.

### Deprecated

- The pre-0.12.0 `<donedata>` key,
  `statifier_persistence:run_status`, is still **read** in this release and is
  **dropped in 0.13.0**: where both are present the new key wins, and reading
  the old one logs one deprecation line at `:debug` naming the new key. Update
  your charts' `<param name="...">` before 0.13.0. It is the only
  transitional reader this rename ships.
