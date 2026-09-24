defmodule StatifierPersistence.Testing.StorageConformance do
  @moduledoc """
  The conformance suite every `StatifierPersistence.Storage.Adapter` must
  pass. Ships in `lib/` (ADR-0003 decision 5, st-ADR-0053's shape) so an
  adapter in another package runs the identical suite:

      defmodule MyApp.EctoAdapterConformanceTest do
        use StatifierPersistence.Testing.StorageConformance,
          adapter: MyApp.EctoAdapter,
          opts: [repo: MyApp.Repo]
      end

  Every test generated here goes through either the adapter directly (the
  callbacks in `StatifierPersistence.Storage.Adapter`) or through
  `StatifierPersistence.Storage`, the guarded facade every adapter sits
  behind. Nothing here reaches into `test/` - the fixtures come from
  `StatifierPersistence.Testing.Charts`, the sibling module this one is
  named alongside, so the one-way `StatifierPersistence.Testing.*` rule
  (ADR-0003 decision 5) holds for both.

  `init/1` is called once per test, in `setup`, so every generated test
  starts from a fresh handle. When the adapter under test exports the
  optional `c:StatifierPersistence.Storage.Adapter.isolate/1` callback,
  `setup` calls it right after `init/1` - the hook an adapter backed by a
  shared resource (a database connection, a sandbox checkout) uses to wrap
  the test that follows in its own isolated unit. An adapter that exports
  no such callback, like `StatifierPersistence.Storage.InMemory`, is
  unaffected: the check is a `function_exported?/3` guard, not a
  requirement.

  That `setup` is the only callback this module registers, and it writes
  nothing: it opens a handle and, when the adapter exports `isolate/1`,
  isolates it. Every row a generated case needs it inserts inside the case
  body, so the first write against the adapter is always the running
  test's own.

  That matters because ExUnit runs `setup` callbacks in the order they are
  defined, and the ones this template registers are defined where you write
  `use`. A host whose adapter needs a per-test binding established before
  any write - a session parameter, a connection-scoped setting, a sandbox
  checkout - must define that `setup` **above** the `use`:

      defmodule MyApp.EctoAdapterConformanceTest do
        setup do
          MyApp.Tenant.bind!(...)
          :ok
        end

        use StatifierPersistence.Testing.StorageConformance,
          adapter: MyApp.EctoAdapter,
          opts: [repo: MyApp.Repo]
      end

  A `setup` written below the `use` runs after every callback this template
  registers. What the template guarantees such a callback is that no row
  has been written yet - not that nothing has run: the handle in
  `context.store` is already open, and already isolated, by the time it is
  called.

  The optional execution `metadata` map (ADR-0006) is treated differently again:
  its cases are generated for every adapter and assert the answer this
  adapter gives - a round trip when it declares support through
  `c:StatifierPersistence.Storage.Adapter.supports_metadata?/1`, a
  `{:error, :metadata_unsupported}` refusal at open when it does not.
  Refusing is conformance; silently dropping the map is not, and that is
  the failure these cases exist to catch.

  The optional `c:StatifierPersistence.Storage.Adapter.lock_execution/3` gets the
  same treatment at generation time: when the adapter under test exports
  it, the suite generates the per-execution lock tests (mutual exclusion of two
  concurrent bodies, release after a raising fun); when it does not, they
  are not generated at all - exporting the callback is what opts an
  adapter into its contract.

  Opting out by not exporting is the whole story for an adapter written
  from scratch. It is not the whole story for
  `StatifierPersistence.Storage.Ecto`, which exports `lock_execution/3`,
  `list_executions_by_metadata/2` and `list_execution_states_by_metadata/2` for every
  Ecto backend but implements all three in Postgres-only SQL
  (`pg_advisory_xact_lock` plus `FOR UPDATE`; `jsonb` containment). Point
  that adapter at a backend that is not Postgres and the four cases those
  three callbacks generate are generated and fail: the lock pair on SQL
  the backend does not parse, the two listings on the refusal they answer
  with instead. `list_executions_by_metadata/2` and
  `list_execution_states_by_metadata/2` consult `supports_metadata?/1` before
  they issue anything, so off Postgres they return
  `{:error, :metadata_unsupported}` rather than raising (sp-4eo) - a
  cleaner answer, but not the list these two cases assert over, so their
  tag stays where the raise put it.

  So those four carry `@tag :postgres`, and such a host excludes them by
  tag rather than forking the suite:

      mix test --exclude postgres

  Nothing else in the suite is tagged: every remaining case runs, and a
  green execution with four excluded is the honest report of what that backend
  supports. It is honest only alongside actually declining what the tag
  excludes - `serialization:` pointed at the host's own strategy rather
  than the adapter's `lock_execution/3`, and no reliance on the child listings.
  Excluding the tag while still routing serialization through a lock the
  backend cannot honor hides a failure instead of opting out of a
  contract. `docs/non-postgres-backends.md` in this package is the guide:
  what declining costs, and how to verify.
  """

  use ExUnit.CaseTemplate

  using options do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [
            conformance_adapter: Keyword.fetch!(options, :adapter),
            conformance_adapter_opts: Keyword.get(options, :opts, [])
          ] do
      alias Statifier.Machine
      alias Statifier.Machine.Identity
      alias StatifierPersistence.Execution.Linkage
      alias StatifierPersistence.Storage
      alias StatifierPersistence.Testing.Charts

      @conformance_adapter conformance_adapter
      @conformance_adapter_opts conformance_adapter_opts

      setup do
        {:ok, store} = Storage.new(@conformance_adapter, @conformance_adapter_opts)

        if function_exported?(@conformance_adapter, :isolate, 1) do
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          :ok = apply(@conformance_adapter, :isolate, [store.opts])
        end

        %{store: store}
      end

      # -- Adapter level -----------------------------------------------

      # sabotage: in the adapter under test's save_chart/2, store under a
      # fixed key instead of content_hash -> red, fetch_chart/2 below would
      # then raise FunctionClauseError/return :chart_not_found instead of
      # the round-tripped record. Verified red, reverted.
      test "adapter: round-trips a saved chart", %{store: store} do
        chart_record = %{
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          chart_blob: <<4, 5, 6>>
        }

        assert :ok = @conformance_adapter.save_chart(store.opts, chart_record)

        assert {:ok, ^chart_record} =
                 @conformance_adapter.fetch_chart(store.opts, "sha256:conformance-chart-a")
      end

      # sabotage: in the adapter under test's save_chart/2, append instead
      # of overwriting on a repeated content_hash -> red, the second assert
      # below would fail because two writes would no longer be
      # indistinguishable from one. Verified red, reverted.
      test "adapter: save_chart/2 is idempotent on a repeated content_hash", %{store: store} do
        chart_record = %{
          content_hash: "sha256:conformance-chart-b",
          identity_blob: <<1, 2, 3>>,
          chart_blob: <<4, 5, 6>>
        }

        assert :ok = @conformance_adapter.save_chart(store.opts, chart_record)
        assert :ok = @conformance_adapter.save_chart(store.opts, chart_record)

        assert {:ok, ^chart_record} =
                 @conformance_adapter.fetch_chart(store.opts, "sha256:conformance-chart-b")
      end

      # sabotage: in the adapter under test's fetch_chart/2, return
      # {:ok, nil} instead of :chart_not_found for an unknown hash -> red,
      # this test's pattern match on {:error, :chart_not_found} would fail.
      # Verified red, reverted.
      test "adapter: fetch_chart/2 reports :chart_not_found for an unknown hash", %{
        store: store
      } do
        assert {:error, :chart_not_found} =
                 @conformance_adapter.fetch_chart(store.opts, "sha256:conformance-missing")
      end

      # sabotage: in the adapter under test's save_position/2, store under a
      # fixed key instead of session_id -> red, fetch_position/2 below
      # would return :position_not_found instead of the round-tripped
      # record. Verified red, reverted.
      test "adapter: round-trips a saved position", %{store: store} do
        position_record = %{
          session_id: "sess_conformance_a",
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: <<7, 8, 9>>
        }

        assert :ok = @conformance_adapter.save_position(store.opts, position_record)

        assert {:ok, ^position_record} =
                 @conformance_adapter.fetch_position(store.opts, "sess_conformance_a")
      end

      # sabotage: in the adapter under test's save_position/2, merge into a
      # prior position instead of overwriting it -> red, the fetch below
      # would return the first record's fields instead of the second's.
      # Verified red, reverted.
      test "adapter: save_position/2 overwrites a prior position for the same session_id", %{
        store: store
      } do
        first = %{
          session_id: "sess_conformance_b",
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: <<7, 8, 9>>
        }

        second = %{
          session_id: "sess_conformance_b",
          content_hash: "sha256:conformance-chart-b",
          identity_blob: <<10, 11, 12>>,
          position_blob: <<13, 14, 15>>
        }

        assert :ok = @conformance_adapter.save_position(store.opts, first)
        assert :ok = @conformance_adapter.save_position(store.opts, second)

        assert {:ok, ^second} =
                 @conformance_adapter.fetch_position(store.opts, "sess_conformance_b")
      end

      # sabotage: in the adapter under test's fetch_position/2, return
      # {:ok, nil} instead of :position_not_found for an unknown session id
      # -> red, this test's pattern match on {:error, :position_not_found}
      # would fail. Verified red, reverted.
      test "adapter: fetch_position/2 reports :position_not_found for an unknown session_id", %{
        store: store
      } do
        assert {:error, :position_not_found} =
                 @conformance_adapter.fetch_position(store.opts, "sess_conformance_missing")
      end

      # sabotage: in the adapter under test's fetch_chart/2, re-encode the
      # returned chart_blob (append a trailing byte instead of returning it
      # verbatim) -> red, the equality assertions on chart_blob and
      # identity_blob below would fail. This is the assertion the plan
      # names explicitly: an adapter must not normalize, truncate, or
      # re-encode stored bytes. Verified red, reverted.
      test "adapter: returns chart blobs byte-identical to what was stored", %{store: store} do
        chart_blob = <<0, 255, 1, 2, 3, 0, 0, 254>>
        identity_blob = <<9, 0, 8, 255, 7>>

        chart_record = %{
          content_hash: "sha256:conformance-byte-identity",
          identity_blob: identity_blob,
          chart_blob: chart_blob
        }

        assert :ok = @conformance_adapter.save_chart(store.opts, chart_record)

        assert {:ok, fetched} =
                 @conformance_adapter.fetch_chart(store.opts, "sha256:conformance-byte-identity")

        assert fetched.chart_blob == chart_blob
        assert fetched.identity_blob == identity_blob
      end

      # sabotage: in the adapter under test's fetch_position/2, re-encode
      # the returned position_blob (append a trailing byte instead of
      # returning it verbatim) -> red, the equality assertion on
      # position_blob below would fail. Verified red, reverted.
      test "adapter: returns position blobs byte-identical to what was stored", %{store: store} do
        position_blob = <<0, 255, 1, 2, 3, 0, 0, 254>>

        position_record = %{
          session_id: "sess_conformance_byte_identity",
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: position_blob
        }

        assert :ok = @conformance_adapter.save_position(store.opts, position_record)

        assert {:ok, fetched} =
                 @conformance_adapter.fetch_position(
                   store.opts,
                   "sess_conformance_byte_identity"
                 )

        assert fetched.position_blob == position_blob
      end

      # -- Adapter level: execution records ------------------------------------

      # sabotage: in the adapter under test's insert_execution/2, store under a
      # fixed key instead of execution_id -> red, fetch_execution/2 below returned
      # {:error, :execution_not_found} instead of the round-tripped record.
      # Verified red, reverted.
      test "adapter: round-trips an inserted execution byte-identically", %{store: store} do
        execution_record = %{
          execution_id: "execution-conformance-a",
          status: :active,
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<9, 0, 8, 255, 7>>,
          position_blob: <<0, 255, 1, 2, 3, 0, 0, 254>>,
          failure: nil,
          metadata: %{},
          outcome_blob: nil
        }

        assert :ok = @conformance_adapter.insert_execution(store.opts, execution_record)

        assert {:ok, ^execution_record} =
                 @conformance_adapter.fetch_execution(store.opts, "execution-conformance-a")
      end

      # sabotage: in the adapter under test's insert_execution/2, drop the
      # exists-check and always write with :ok -> red, the second insert
      # below returned :ok instead of {:error, :execution_exists}. Verified red
      # (together with InMemoryTest's concurrent-insert test under this one
      # mutation), reverted.
      test "adapter: insert_execution/2 refuses a duplicate execution_id with :execution_exists",
           %{store: store} do
        execution_record = %{
          execution_id: "execution-conformance-duplicate",
          status: :active,
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: <<7, 8, 9>>,
          failure: nil,
          metadata: %{},
          outcome_blob: nil
        }

        assert :ok = @conformance_adapter.insert_execution(store.opts, execution_record)

        assert {:error, :execution_exists} =
                 @conformance_adapter.insert_execution(store.opts, %{
                   execution_record
                   | status: :failed
                 })

        assert {:ok, ^execution_record} =
                 @conformance_adapter.fetch_execution(
                   store.opts,
                   "execution-conformance-duplicate"
                 )
      end

      # sabotage: in the adapter under test's update_execution/2, upsert on a
      # missing execution_id (write and return :ok) instead of refusing -> red,
      # the update below returned :ok instead of {:error, :execution_not_found}.
      # Verified red, reverted.
      test "adapter: update_execution/2 reports :execution_not_found for an unknown execution_id",
           %{store: store} do
        execution_record = %{
          execution_id: "execution-conformance-update-missing",
          status: :failed,
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: nil,
          failure: "abandoned",
          metadata: %{},
          outcome_blob: nil
        }

        assert {:error, :execution_not_found} =
                 @conformance_adapter.update_execution(store.opts, execution_record)

        assert {:error, :execution_not_found} =
                 @conformance_adapter.fetch_execution(
                   store.opts,
                   "execution-conformance-update-missing"
                 )
      end

      # sabotage: in the adapter under test's fetch_execution/2, return
      # {:ok, a_placeholder_record} instead of :execution_not_found for an
      # unknown id -> red, this test's pattern match on
      # {:error, :execution_not_found} saw the placeholder. Verified red,
      # reverted.
      test "adapter: fetch_execution/2 reports :execution_not_found for an unknown execution_id",
           %{store: store} do
        assert {:error, :execution_not_found} =
                 @conformance_adapter.fetch_execution(store.opts, "execution-conformance-missing")
      end

      # sabotage: in the adapter under test's insert_execution/2, normalize a nil
      # position_blob to <<>> before storing -> red, the equality assertion
      # on nil below saw "" instead. This is the arm ADR-0004 decision 1
      # makes nullable; an adapter must not paper over it. Verified red,
      # reverted.
      test "adapter: a nil position_blob round-trips as nil", %{store: store} do
        execution_record = %{
          execution_id: "execution-conformance-nil-blob",
          status: :failed,
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: nil,
          failure: "budget_exhausted: 100 rounds",
          metadata: %{},
          outcome_blob: nil
        }

        assert :ok = @conformance_adapter.insert_execution(store.opts, execution_record)

        assert {:ok, fetched} =
                 @conformance_adapter.fetch_execution(
                   store.opts,
                   "execution-conformance-nil-blob"
                 )

        assert fetched.position_blob == nil
      end

      # sabotage: in the adapter under test's update_execution/2, keep the stored
      # record's status and failure instead of overwriting them (a partial
      # update) -> red, the fetch below returned the inserted :active/nil
      # pair instead of the updated :failed/reason pair. Verified red,
      # reverted.
      test "adapter: update_execution/2 overwrites the full record, status and failure verbatim",
           %{
             store: store
           } do
        inserted = %{
          execution_id: "execution-conformance-overwrite",
          status: :active,
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: <<7, 8, 9>>,
          failure: nil,
          metadata: %{},
          outcome_blob: nil
        }

        updated = %{
          inserted
          | status: :failed,
            position_blob: <<10, 11, 12>>,
            failure: "abandoned: operator request"
        }

        assert :ok = @conformance_adapter.insert_execution(store.opts, inserted)
        assert :ok = @conformance_adapter.update_execution(store.opts, updated)

        assert {:ok, ^updated} =
                 @conformance_adapter.fetch_execution(
                   store.opts,
                   "execution-conformance-overwrite"
                 )
      end

      # sabotage: in StatifierPersistence.Storage.Ecto's @statuses list,
      # drop the cancelled: "cancelled" entry -> red,
      # encode_status(:cancelled) has no matching clause and this test's
      # insert raises FunctionClauseError instead of storing the record.
      # Verified red on the Ecto conformance suite, reverted.
      test "adapter: a :cancelled execution round-trips through insert_execution/2 and update_execution/2 with its position untouched",
           %{store: store} do
        inserted = %{
          execution_id: "execution-conformance-cancelled",
          status: :cancelled,
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: <<7, 8, 9>>,
          failure: nil,
          metadata: %{},
          outcome_blob: nil
        }

        assert :ok = @conformance_adapter.insert_execution(store.opts, inserted)

        assert {:ok, ^inserted} =
                 @conformance_adapter.fetch_execution(
                   store.opts,
                   "execution-conformance-cancelled"
                 )

        updated = %{inserted | status: :cancelled}
        assert :ok = @conformance_adapter.update_execution(store.opts, updated)

        assert {:ok, fetched} =
                 @conformance_adapter.fetch_execution(
                   store.opts,
                   "execution-conformance-cancelled"
                 )

        assert fetched.status == :cancelled
        assert fetched.position_blob == inserted.position_blob
      end

      # -- Adapter level: the optional child enumeration (ADR-0008) -----
      #
      # Generated only when the adapter under test exports the optional
      # list_executions_by_metadata/2 - the same opt-in-by-export shape lock_execution/3
      # gets above.

      if Code.ensure_loaded?(conformance_adapter) and
           function_exported?(conformance_adapter, :list_executions_by_metadata, 2) do
        # sabotage: in StatifierPersistence.Storage.InMemory's private
        # contains?/2, drop the is_map/is_map guarded clause that recurses
        # into a nested map value, leaving only the plain == comparison ->
        # red, the nested-match assertion below found no executions instead of
        # the one whose nested map contains the given pair. Verified red on
        # the InMemory conformance suite, reverted.
        @tag :postgres
        test "adapter: list_executions_by_metadata/2 matches a nested map by containment and excludes the rest",
             %{store: store} do
          linked = %{
            execution_id: "execution-conformance-child-linked",
            status: :active,
            content_hash: "sha256:conformance-chart-a",
            identity_blob: <<1, 2, 3>>,
            position_blob: <<7, 8, 9>>,
            failure: nil,
            metadata: %{
              "statifier_persistence" => %{
                "parent_execution_id" => "execution-conformance-parent",
                "invoke_id" => "call"
              }
            },
            outcome_blob: nil
          }

          other_parent = %{
            linked
            | execution_id: "execution-conformance-child-other-parent",
              metadata: %{
                "statifier_persistence" => %{
                  "parent_execution_id" => "execution-conformance-other-parent",
                  "invoke_id" => "call"
                }
              }
          }

          unrelated = %{linked | execution_id: "execution-conformance-unrelated", metadata: %{}}

          assert :ok = @conformance_adapter.insert_execution(store.opts, linked)
          assert :ok = @conformance_adapter.insert_execution(store.opts, other_parent)
          assert :ok = @conformance_adapter.insert_execution(store.opts, unrelated)

          assert {:ok, matches} =
                   @conformance_adapter.list_executions_by_metadata(store.opts, %{
                     "statifier_persistence" => %{
                       "parent_execution_id" => "execution-conformance-parent"
                     }
                   })

          assert Enum.map(matches, & &1.execution_id) == ["execution-conformance-child-linked"]
        end
      end

      # -- Adapter level: the optional outcome payload and the status
      # projection (sp-t57) ---------------------------------------------
      #
      # Generated only for an adapter that exports each, the same
      # opt-in-by-export shape the child enumeration above uses. An adapter
      # that exports neither is conformant unchanged: nothing but a fan-out
      # child needs either, and Driver.start_child_at/6 refuses at open
      # rather than starting one it could not settle.

      if Code.ensure_loaded?(conformance_adapter) and
           function_exported?(conformance_adapter, :supports_execution_outcome?, 1) do
        # sabotage: in StatifierPersistence.Storage.InMemory's private
        # carry_forward/2, drop the `|| Map.get(stored, :outcome_blob)`
        # fallback so a nil in the given record overwrites the stored one
        # -> red, the final fetch below came back with a nil outcome_blob
        # instead of the payload the earlier update wrote. Verified red on
        # the InMemory conformance suite, reverted. Also verified on the
        # Ecto side: make outcome_update(nil) return
        # [outcome_blob: nil] rather than [] -> red the same way.
        test "adapter: outcome_blob round-trips and survives a later status-only update",
             %{store: store} do
          inserted = %{
            execution_id: "execution-conformance-outcome",
            status: :active,
            content_hash: "sha256:conformance-chart-a",
            identity_blob: <<1, 2, 3>>,
            position_blob: <<7, 8, 9>>,
            failure: nil,
            metadata: %{},
            outcome_blob: nil
          }

          assert :ok = @conformance_adapter.insert_execution(store.opts, inserted)

          assert {:ok, %{outcome_blob: nil}} =
                   @conformance_adapter.fetch_execution(
                     store.opts,
                     "execution-conformance-outcome"
                   )

          answered = %{inserted | status: :completed, outcome_blob: <<42, 43>>}
          assert :ok = @conformance_adapter.update_execution(store.opts, answered)

          assert {:ok, %{outcome_blob: <<42, 43>>}} =
                   @conformance_adapter.fetch_execution(
                     store.opts,
                     "execution-conformance-outcome"
                   )

          # A later write carrying no payload must not erase the stored one:
          # nil means unchanged, which is what keeps an ordinary step of an
          # already-answered execution from clearing its answer.
          stepped = %{answered | position_blob: <<9, 9>>, outcome_blob: nil}
          assert :ok = @conformance_adapter.update_execution(store.opts, stepped)

          assert {:ok, fetched} =
                   @conformance_adapter.fetch_execution(
                     store.opts,
                     "execution-conformance-outcome"
                   )

          assert fetched.outcome_blob == <<42, 43>>
          assert fetched.position_blob == <<9, 9>>
        end
      end

      if Code.ensure_loaded?(conformance_adapter) and
           function_exported?(conformance_adapter, :list_execution_states_by_metadata, 2) do
        # sabotage: in StatifierPersistence.Storage.InMemory's private
        # to_execution_state/1, read "child_index" off the whole metadata map
        # instead of the reserved sub-map -> red, every projected row came
        # back with a nil child_index instead of 0 and 1. Verified red on
        # the InMemory conformance suite, reverted. Also verified on the
        # Ecto side: replace the child_index fragment with NULL::text ->
        # red the same way.
        @tag :postgres
        test "adapter: list_execution_states_by_metadata/2 projects id, status and index without blobs",
             %{store: store} do
          child = fn index, status ->
            %{
              execution_id: "execution-conformance-state-#{index}",
              status: status,
              content_hash: "sha256:conformance-chart-a",
              identity_blob: <<1, 2, 3>>,
              position_blob: <<7, 8, 9>>,
              failure: nil,
              metadata: %{
                "statifier_persistence" => %{
                  "parent_execution_id" => "execution-conformance-state-parent",
                  "invoke_id" => "call",
                  "child_index" => index,
                  "content_hash" => "sha256:conformance-chart-a",
                  "child_count" => 2,
                  "policy" => "all"
                }
              },
              outcome_blob: nil
            }
          end

          assert :ok = @conformance_adapter.insert_execution(store.opts, child.(0, :completed))
          assert :ok = @conformance_adapter.insert_execution(store.opts, child.(1, :active))

          assert {:ok, states} =
                   @conformance_adapter.list_execution_states_by_metadata(store.opts, %{
                     "statifier_persistence" => %{
                       "parent_execution_id" => "execution-conformance-state-parent",
                       "invoke_id" => "call"
                     }
                   })

          assert Enum.sort_by(states, & &1.child_index) == [
                   %{
                     execution_id: "execution-conformance-state-0",
                     status: :completed,
                     child_index: 0
                   },
                   %{
                     execution_id: "execution-conformance-state-1",
                     status: :active,
                     child_index: 1
                   }
                 ]

          # The rows are a projection, not records: no blob ever rides one.
          for state <- states do
            refute Map.has_key?(state, :position_blob)
            refute Map.has_key?(state, :identity_blob)
          end
        end
      end

      # -- Adapter level: the optional drained query (ADR-0012) ----------
      #
      # Generated only when the adapter under test exports the optional
      # count_executions_by_content_hash/2 - the same opt-in-by-export
      # shape every optional callback above uses.
      #
      # Untagged, like the input log and unlike the two listings: the
      # query is an equality predicate and a GROUP BY, which needs no
      # Postgres-only feature, so these cases are the contract on every
      # backend.

      if Code.ensure_loaded?(conformance_adapter) and
           function_exported?(conformance_adapter, :count_executions_by_content_hash, 2) do
        # sabotage: in the adapter under test's
        # count_executions_by_content_hash/2, fold onto %{} instead of
        # onto @zero_counts, so the answer carries only the arms the
        # store holds rows in -> red, this case's unknown hash came back
        # as %{} rather than the zero keys. Verified red on both
        # conformance suites, four cases red in each ("35 tests, 4
        # failures" over InMemory, "40 tests, 4 failures" over Ecto).
        # Reverted from a copy.
        test "adapter: an unknown content hash answers every key at zero", %{store: store} do
          assert {:ok, counts} =
                   @conformance_adapter.count_executions_by_content_hash(
                     store.opts,
                     "sha256:conformance-never-stored"
                   )

          assert counts == %{
                   active: 0,
                   needs_migration: 0,
                   completed: 0,
                   failed: 0,
                   cancelled: 0,
                   children: 0
                 }
        end

        # sabotage: in the adapter under test's
        # count_executions_by_content_hash/2, drop the content_hash
        # predicate (the Enum.filter/2 on the in-memory side, the where:
        # clause on the Ecto side) -> red, the first chart counted the
        # second chart's executions too. Verified red on both conformance
        # suites, this case alone in each ("35 tests, 1 failure" over
        # InMemory, "40 tests, 1 failure" over Ecto). Reverted from a
        # copy.
        test "adapter: two charts' executions never count into each other", %{store: store} do
          insert_counted_execution(store, "counts-a-active", "sha256:counts-a", :active)
          insert_counted_execution(store, "counts-b-active", "sha256:counts-b", :active)
          insert_counted_execution(store, "counts-b-done", "sha256:counts-b", :completed)

          assert {:ok, a} =
                   @conformance_adapter.count_executions_by_content_hash(
                     store.opts,
                     "sha256:counts-a"
                   )

          assert {:ok, b} =
                   @conformance_adapter.count_executions_by_content_hash(
                     store.opts,
                     "sha256:counts-b"
                   )

          assert a.active == 1
          assert a.completed == 0
          assert b.active == 1
          assert b.completed == 1
        end

        # sabotage: in the in-memory adapter's
        # count_executions_by_content_hash/2, count every matched row into
        # :active rather than into its own status
        # (Map.update!(counts, :active, ...)) -> red, the second
        # assertion below still read active: 1, completed: 0 after the
        # execution had completed. Verified red on the InMemory
        # conformance suite, two cases red ("35 tests, 2 failures" - this
        # one and the two-charts case). Reverted from a copy.
        test "adapter: an execution that completes moves from the active key to the completed one",
             %{store: store} do
          inserted =
            insert_counted_execution(store, "counts-moving", "sha256:counts-moving", :active)

          assert {:ok, %{active: 1, completed: 0}} =
                   @conformance_adapter.count_executions_by_content_hash(
                     store.opts,
                     "sha256:counts-moving"
                   )

          assert :ok =
                   @conformance_adapter.update_execution(
                     store.opts,
                     %{inserted | status: :completed}
                   )

          assert {:ok, %{active: 0, completed: 1}} =
                   @conformance_adapter.count_executions_by_content_hash(
                     store.opts,
                     "sha256:counts-moving"
                   )
        end

        # ADR-0014 decisions 1 and 4: the fifth arm is stored, read back
        # and counted under its own key. A hold parked on its chart is
        # neither :active nor terminal, and the drained query says so.
        #
        # sabotage: drop `needs_migration: 0` from the in-memory adapter's
        # @zero_counts and the `needs_migration: "needs_migration"` entry from
        # the Ecto adapter's @statuses -> red on both conformance suites: the
        # in-memory fold raised KeyError on the parked row, and the Ecto insert
        # raised FunctionClauseError in encode_status/1. Verified red, reverted
        # from a copy.
        test "adapter: a parked execution round-trips and counts under needs_migration, never under active",
             %{store: store} do
          inserted =
            insert_counted_execution(
              store,
              "hold-parked",
              "sha256:counts-parked-hold",
              :needs_migration
            )

          assert {:ok, ^inserted} =
                   @conformance_adapter.fetch_execution(store.opts, "hold-parked")

          insert_counted_execution(store, "hold-waiting", "sha256:counts-parked-hold", :active)

          assert {:ok, counts} =
                   @conformance_adapter.count_executions_by_content_hash(
                     store.opts,
                     "sha256:counts-parked-hold"
                   )

          assert counts == %{
                   active: 1,
                   needs_migration: 1,
                   completed: 0,
                   failed: 0,
                   cancelled: 0,
                   children: 0
                 }

          assert :ok =
                   @conformance_adapter.update_execution(store.opts, %{inserted | status: :active})

          assert {:ok, %{active: 2, needs_migration: 0}} =
                   @conformance_adapter.count_executions_by_content_hash(
                     store.opts,
                     "sha256:counts-parked-hold"
                   )
        end

        # -- the children key: ADR-0012 decision 1's child clause --------
        #
        # Generated only where the adapter under test also holds
        # metadata: a linkage lives under the reserved metadata key, so
        # an adapter that drops metadata holds no pin to count and the
        # zero it answers is already covered by the unknown-hash case
        # above.

        if Code.ensure_loaded?(conformance_adapter) and
             function_exported?(conformance_adapter, :supports_metadata?, 1) do
          # sabotage: in the adapter under test's children count, drop
          # the parent-status predicate (the `where: parent.status ==
          # ^encode_status(:active)` clause on the Ecto side, the
          # `match?(%{status: :active}, ...)` on the in-memory side, the
          # latter left as a bare key lookup) -> red, the last assertion
          # below read children: 2 after the parent had completed, where
          # it asserts 0. Verified red over the two conformance suites
          # and `StatifierPersistence.ExecutionsTest` in one run ("130
          # tests, 3 failures"): this case on both adapters, plus that
          # module's own entry-level case. Reverted from the copies.
          test "adapter: a parent's two durable children count on the child chart, and stop counting when the parent leaves the active arm",
               %{store: store} do
            parent =
              insert_counted_execution(
                store,
                "counts-pin-parent",
                "sha256:counts-pin-parent",
                :active
              )

            for index <- 0..1 do
              insert_pinned_child(
                store,
                "counts-pin-parent/call/#{index}",
                "sha256:counts-pin-child",
                index,
                :active
              )
            end

            assert {:ok, %{children: 2}} =
                     @conformance_adapter.count_executions_by_content_hash(
                       store.opts,
                       "sha256:counts-pin-child"
                     )

            # The parent's own chart carries no pin: pins name the
            # child's chart, and the parent is nobody's child here.
            assert {:ok, %{children: 0}} =
                     @conformance_adapter.count_executions_by_content_hash(
                       store.opts,
                       "sha256:counts-pin-parent"
                     )

            assert :ok =
                     @conformance_adapter.update_execution(
                       store.opts,
                       %{parent | status: :completed}
                     )

            assert {:ok, %{children: 0}} =
                     @conformance_adapter.count_executions_by_content_hash(
                       store.opts,
                       "sha256:counts-pin-child"
                     )
          end

          # The inversion this case exists to catch: it is the PARENT's
          # arm that decides, never the child's. A terminal child of an
          # active parent is still reachable (ADR-0012 decision 1), so
          # it counts, and an implementation reading the child's own
          # status instead reads 0 here.
          #
          # sabotage: in the adapter under test's children count, test
          # the CHILD's status for :active rather than the parent's
          # (`where: child.status == ^encode_status(:active)` on the
          # Ecto side, `execution.status == :active` on the in-memory
          # side) -> red, this case read 0 where it asserts children ==
          # 1. Verified red over the two conformance suites and
          # `StatifierPersistence.ExecutionsTest` in one run ("130
          # tests, 6 failures"): this case on both adapters, and four
          # more the inversion also breaks. Reverted from the copies.
          test "adapter: a terminal child of an active parent still counts", %{store: store} do
            insert_counted_execution(
              store,
              "counts-terminal-parent",
              "sha256:counts-terminal-parent",
              :active
            )

            insert_pinned_child(
              store,
              "counts-terminal-parent/call/0",
              "sha256:counts-terminal-child",
              0,
              :completed
            )

            assert {:ok, counts} =
                     @conformance_adapter.count_executions_by_content_hash(
                       store.opts,
                       "sha256:counts-terminal-child"
                     )

            assert counts.children == 1
            assert counts.completed == 1
            assert counts.active == 0
          end

          # A parked parent can take a step again once it leaves the arm,
          # so it can read its child's pin again: the pin counts
          # (ADR-0014 decision 4).
          #
          # sabotage: read "the parent is :active" alone as the pin (the
          # in-memory @pinning_statuses and the Ecto pinning_statuses/0 cut to
          # the :active arm) -> red on both conformance suites, this case read
          # children: 0 under a parked parent. Verified red, reverted from the
          # copies.
          test "adapter: a durable child's pin counts while its parent is parked", %{
            store: store
          } do
            parent =
              insert_counted_execution(
                store,
                "counts-parked-parent",
                "sha256:counts-parked-parent",
                :needs_migration
              )

            insert_pinned_child(
              store,
              "counts-parked-parent/call/0",
              "sha256:counts-parked-child",
              0,
              :completed
            )

            assert {:ok, %{children: 1}} =
                     @conformance_adapter.count_executions_by_content_hash(
                       store.opts,
                       "sha256:counts-parked-child"
                     )

            assert :ok =
                     @conformance_adapter.update_execution(
                       store.opts,
                       %{parent | status: :cancelled}
                     )

            assert {:ok, %{children: 0}} =
                     @conformance_adapter.count_executions_by_content_hash(
                       store.opts,
                       "sha256:counts-parked-child"
                     )
          end

          # sabotage: in the adapter under test's children count, take
          # the hash from the child row's own content_hash instead of
          # from its linkage pin (`where: child.content_hash ==
          # ^content_hash` in place of the containment clause on the
          # Ecto side, a `when execution.content_hash == content_hash`
          # guard in place of the pinned match on the in-memory side) ->
          # red, the pinned hash came back children: 0 and the row's own
          # hash came back children: 1, the exact reverse of what this
          # case asserts. Verified red over the two conformance suites
          # and `StatifierPersistence.ExecutionsTest` in one run ("130
          # tests, 2 failures"): this case on both adapters and nothing
          # else. Reverted from the copies.
          test "adapter: the pin decides, not the child row's own content hash", %{store: store} do
            insert_counted_execution(
              store,
              "counts-pinned-parent",
              "sha256:counts-pinned-parent",
              :active
            )

            record = %{
              execution_id: "counts-pinned-parent/call/0",
              status: :active,
              content_hash: "sha256:counts-row-hash",
              identity_blob: <<1, 2, 3>>,
              position_blob: <<7, 8, 9>>,
              failure: nil,
              metadata:
                Linkage.to_metadata(
                  Linkage.new("counts-pinned-parent", "call", 0, "sha256:counts-pin-hash")
                ),
              outcome_blob: nil
            }

            assert :ok = @conformance_adapter.insert_execution(store.opts, record)

            assert {:ok, %{children: 1}} =
                     @conformance_adapter.count_executions_by_content_hash(
                       store.opts,
                       "sha256:counts-pin-hash"
                     )

            assert {:ok, %{children: 0, active: 1}} =
                     @conformance_adapter.count_executions_by_content_hash(
                       store.opts,
                       "sha256:counts-row-hash"
                     )
          end

          # sabotage: in the adapter under test's children count, drop
          # the join to the parent row entirely and count every matching
          # pin (the `join:`/`on:` and the status clause on the Ecto
          # side, the parent lookup replaced by `true` on the in-memory
          # side) -> red, this case read children: 1 where it asserts 0.
          # Verified red over the two conformance suites and
          # `StatifierPersistence.ExecutionsTest` in one run ("130
          # tests, 5 failures"): this case on both adapters, and three
          # more that turn on a parent leaving the active arm. Reverted
          # from the copies.
          test "adapter: a pin whose parent execution is not stored counts nothing", %{
            store: store
          } do
            insert_pinned_child(
              store,
              "counts-orphan-parent/call/0",
              "sha256:counts-orphan-child",
              0,
              :active
            )

            assert {:ok, %{children: 0}} =
                     @conformance_adapter.count_executions_by_content_hash(
                       store.opts,
                       "sha256:counts-orphan-child"
                     )
          end

          defp insert_pinned_child(store, execution_id, content_hash, child_index, status) do
            [parent_execution_id, invoke_id, _index] = String.split(execution_id, "/")

            linkage =
              Linkage.new(parent_execution_id, invoke_id, child_index, content_hash)

            record = %{
              execution_id: execution_id,
              status: status,
              content_hash: content_hash,
              identity_blob: <<1, 2, 3>>,
              position_blob: <<7, 8, 9>>,
              failure: nil,
              metadata: Linkage.to_metadata(linkage),
              outcome_blob: nil
            }

            assert :ok = @conformance_adapter.insert_execution(store.opts, record)

            record
          end
        end

        defp insert_counted_execution(store, execution_id, content_hash, status) do
          record = %{
            execution_id: execution_id,
            status: status,
            content_hash: content_hash,
            identity_blob: <<1, 2, 3>>,
            position_blob: <<7, 8, 9>>,
            failure: nil,
            metadata: %{},
            outcome_blob: nil
          }

          assert :ok = @conformance_adapter.insert_execution(store.opts, record)

          record
        end
      end

      # The capability itself is asserted for every adapter, supporting or
      # not: an adapter that cannot answer the drained query stays
      # conformant by declining it, and the facade refuses at open without
      # calling it (ADR-0012 decision 3). Silently answering a partial map
      # is what neither answer allows.

      # sabotage: in
      # StatifierPersistence.Storage.count_executions_by_content_hash/2,
      # call the adapter unconditionally instead of consulting
      # content_hash_query_supported?/1 -> red on the declining arm: the
      # call raised UndefinedFunctionError instead of returning
      # {:error, :content_hash_query_unsupported}. Verified red on the
      # NoLockAdapter conformance suite, this case alone ("27 tests, 1
      # failure"). Reverted from a copy.
      test "facade: the drained query either counts or is declined at open", %{store: store} do
        answer = Storage.count_executions_by_content_hash(store, "sha256:conformance-capability")

        if Storage.content_hash_query_supported?(store) do
          assert {:ok, counts} = answer

          assert counts == %{
                   active: 0,
                   needs_migration: 0,
                   completed: 0,
                   failed: 0,
                   cancelled: 0,
                   children: 0
                 }
        else
          assert {:error, :content_hash_query_unsupported} = answer
        end
      end

      # -- Adapter level: the optional retirement (ADR-0012) -------------
      #
      # Generated only when the adapter under test exports the optional
      # retire_chart/3, the same opt-in-by-export shape every optional
      # callback above uses.
      #
      # The refusal and the tombstone are one contract and are checked
      # together here for that reason: an adapter that drops a chart's
      # blobs without refusing a pinned one is the failure ADR-0012
      # exists to prevent, and a suite that could pass with only half of
      # it would not be checking the thing.

      if Code.ensure_loaded?(conformance_adapter) and
           function_exported?(conformance_adapter, :retire_chart, 3) do
        @retire_hash "sha256:conformance-retire"

        # sabotage: drop the adapter under test's guard on the :active
        # arm - the `Adapter.pinned?(counts) -> ...` cond clause in the
        # in-memory adapter's retire_stored/4, and the `active` NOT
        # EXISTS clause of the Ecto adapter's unpinned_chart/2 -> red,
        # an :active execution on the hash was retired instead of
        # refused. Verified red on both conformance suites. Reverted
        # from a copy.
        test "adapter: an :active execution on the hash refuses the retirement", %{store: store} do
          save_retirable_chart(store, @retire_hash)
          insert_retire_execution(store, "retire-active", @retire_hash, :active)

          assert {:error, {:pinned, counts}} =
                   @conformance_adapter.retire_chart(store.opts, @retire_hash, retirement())

          assert counts.executions.active == 1
          assert counts.children == 0
          assert counts.positions == 0
          assert counts.sources == %{}

          assert {:ok, chart} = @conformance_adapter.fetch_chart(store.opts, @retire_hash)
          assert chart.chart_blob == <<4, 5, 6>>
        end

        # ADR-0014 decision 4: a parked execution pins the chart it is
        # parked on, and the refusal reports it under its own key.
        #
        # sabotage: drop the `executions.needs_migration > 0` term from
        # StatifierPersistence.Storage.Adapter.pinned?/1 and read the Ecto
        # adapter's unpinned_chart/2 `active` subquery as `:active` alone ->
        # red on both conformance suites, this case alone in each: the parked
        # hold's chart was retired instead of refused. Verified red, reverted
        # from the copies.
        test "adapter: a parked execution on the hash refuses the retirement", %{store: store} do
          save_retirable_chart(store, @retire_hash)
          insert_retire_execution(store, "retire-parked", @retire_hash, :needs_migration)

          assert {:error, {:pinned, counts}} =
                   @conformance_adapter.retire_chart(store.opts, @retire_hash, retirement())

          assert counts.executions.needs_migration == 1
          assert counts.executions.active == 0
          assert counts.children == 0
          assert counts.positions == 0

          assert {:ok, chart} = @conformance_adapter.fetch_chart(store.opts, @retire_hash)
          assert chart.chart_blob == <<4, 5, 6>>
        end

        # sabotage: drop the adapter under test's guard on the position
        # rows - the `positions > 0` term of
        # StatifierPersistence.Storage.Adapter.pinned?/1, and the `held`
        # NOT EXISTS clause of the Ecto adapter's unpinned_chart/2 ->
        # red, a hash carrying a saved position and no execution at all
        # was retired, and the fetch below read the tombstone instead of
        # the bytes. Verified red on both conformance suites. Reverted
        # from a copy.
        test "adapter: a position row on the hash refuses the retirement", %{store: store} do
          save_retirable_chart(store, @retire_hash)

          assert :ok =
                   @conformance_adapter.save_position(store.opts, %{
                     session_id: "sess_conformance_retire",
                     content_hash: @retire_hash,
                     identity_blob: <<1, 2, 3>>,
                     position_blob: <<7, 8, 9>>
                   })

          assert {:error, {:pinned, counts}} =
                   @conformance_adapter.retire_chart(store.opts, @retire_hash, retirement())

          assert counts.positions == 1
          assert counts.executions.active == 0

          assert {:ok, chart} = @conformance_adapter.fetch_chart(store.opts, @retire_hash)
          assert chart.chart_blob == <<4, 5, 6>>
        end

        # The child clause of decision 1 as a refusal rather than as a
        # count: the child is terminal and holds no :active row of its
        # own on the hash, so only its linkage pin, read through its
        # :active parent, can hold the chart. Generated only where the
        # adapter under test also holds metadata, because a linkage
        # lives under the reserved metadata key.
        #
        # sabotage: drop the adapter under test's guard on the children
        # pins - the `children > 0` term of
        # StatifierPersistence.Storage.Adapter.pinned?/1, and the
        # without_child_pins/3 clause of the Ecto adapter's
        # unpinned_chart/2 -> red, the chart under a terminal child of
        # an :active parent was retired instead of refused. Verified red
        # over the storage suites in one run ("308 tests, 3 failures"):
        # this case on the in-memory suite and both Ecto suites, and
        # nothing else. Reverted from the copies.
        if function_exported?(conformance_adapter, :supports_metadata?, 1) do
          test "adapter: a terminal child's pin under an :active parent refuses the retirement",
               %{store: store} do
            save_retirable_chart(store, @retire_hash)
            insert_retire_execution(store, "retire-pin-parent", "sha256:retire-parent", :active)

            assert :ok =
                     @conformance_adapter.insert_execution(store.opts, %{
                       execution_id: "retire-pin-parent/call/0",
                       status: :completed,
                       content_hash: @retire_hash,
                       identity_blob: <<1, 2, 3>>,
                       position_blob: <<7, 8, 9>>,
                       failure: nil,
                       metadata:
                         Linkage.to_metadata(
                           Linkage.new("retire-pin-parent", "call", 0, @retire_hash)
                         ),
                       outcome_blob: nil
                     })

            assert {:error, {:pinned, counts}} =
                     @conformance_adapter.retire_chart(store.opts, @retire_hash, retirement())

            assert counts.children == 1
            assert counts.executions.active == 0
            assert counts.executions.completed == 1
            assert counts.positions == 0

            assert {:ok, chart} = @conformance_adapter.fetch_chart(store.opts, @retire_hash)
            assert chart.chart_blob == <<4, 5, 6>>
          end
        end

        # The child clause of decision 1 under a parked parent, as a refusal.
        #
        # sabotage: the pinning arms cut to :active alone, as for the parked-
        # parent count case above -> red on both conformance suites: the chart
        # under a terminal child of a parked parent was retired instead of
        # refused. Verified red, reverted from the copies.
        if function_exported?(conformance_adapter, :supports_metadata?, 1) do
          test "adapter: a terminal child's pin under a parked parent refuses the retirement",
               %{store: store} do
            save_retirable_chart(store, @retire_hash)

            insert_retire_execution(
              store,
              "retire-parked-parent",
              "sha256:retire-parent",
              :needs_migration
            )

            assert :ok =
                     @conformance_adapter.insert_execution(store.opts, %{
                       execution_id: "retire-parked-parent/call/0",
                       status: :completed,
                       content_hash: @retire_hash,
                       identity_blob: <<1, 2, 3>>,
                       position_blob: <<7, 8, 9>>,
                       failure: nil,
                       metadata:
                         Linkage.to_metadata(
                           Linkage.new("retire-parked-parent", "call", 0, @retire_hash)
                         ),
                       outcome_blob: nil
                     })

            assert {:error, {:pinned, counts}} =
                     @conformance_adapter.retire_chart(store.opts, @retire_hash, retirement())

            assert counts.children == 1
            assert counts.executions.needs_migration == 0

            assert {:ok, chart} = @conformance_adapter.fetch_chart(store.opts, @retire_hash)
            assert chart.chart_blob == <<4, 5, 6>>
          end
        end

        # sabotage: in
        # StatifierPersistence.Storage.Adapter.sources_pinned?/1, answer
        # false unconditionally - the one function both adapters ask
        # about a source's counts -> red, a source reporting a non-zero
        # count did not refuse and the chart was retired. Verified red
        # on both conformance suites. Reverted from a copy.
        test "adapter: a source's non-zero count refuses, under that source's module name",
             %{store: store} do
          save_retirable_chart(store, @retire_hash)
          sources = %{__MODULE__ => %{pending_timers: 2}}

          assert {:error, {:pinned, counts}} =
                   @conformance_adapter.retire_chart(
                     store.opts,
                     @retire_hash,
                     retirement(sources)
                   )

          assert counts.sources == sources
          assert counts.executions.active == 0
          assert counts.positions == 0

          assert {:ok, chart} = @conformance_adapter.fetch_chart(store.opts, @retire_hash)
          assert chart.chart_blob == <<4, 5, 6>>
        end

        # The bytes themselves are not readable from here - every
        # public door answers the retired arm for this hash, which is
        # the contract - so that they are gone is asserted per adapter,
        # where the store can be read directly:
        # StatifierPersistence.RetireChartTest for the in-memory map and
        # StatifierPersistence.Ecto.RetireChartRaceTest for the row.
        #
        # sabotage: in the adapter under test's retire_chart/3, write
        # retired_at and leave retired_by unset (drop it from the
        # in-memory adapter's tombstone/4 and from the Ecto adapter's
        # write_tombstone/3 `set:`) -> red, the answer and the read-back
        # both carried a nil retired_by, so the row no longer said who
        # decided. Verified red on both conformance suites. Reverted
        # from a copy.
        test "adapter: a drained hash is retired, keeping the row and dropping the bytes",
             %{store: store} do
          save_retirable_chart(store, @retire_hash)
          insert_retire_execution(store, "retire-done", @retire_hash, :completed)
          at = DateTime.from_naive!(~N[2026-09-19 18:00:00.000000], "Etc/UTC")

          assert {:ok, info} =
                   @conformance_adapter.retire_chart(store.opts, @retire_hash, %{
                     retired_at: at,
                     retired_by: "conformance-operator",
                     sources: %{}
                   })

          assert info.retired_at == at
          assert info.retired_by == "conformance-operator"

          # The row and its hash survive the removal: that is what makes
          # the retired arm answerable at all, rather than a miss.
          assert {:error, {:chart_retired, read_back}} =
                   @conformance_adapter.fetch_chart(store.opts, @retire_hash)

          assert read_back.retired_at == at
          assert read_back.retired_by == "conformance-operator"

          assert {:ok, counts} =
                   @conformance_adapter.count_executions_by_content_hash(
                     store.opts,
                     @retire_hash
                   )

          assert counts.completed == 1
        end

        # sabotage: in the adapter under test's fetch_chart/2, drop the
        # retired clause so a tombstoned row falls through to the
        # ordinary chart record -> red, the fetch answered {:ok, record}
        # with nil blobs instead of the retired arm. Verified red on
        # both conformance suites. Reverted from a copy.
        test "adapter: a terminal execution never pins, and a retired hash is never a miss",
             %{store: store} do
          save_retirable_chart(store, @retire_hash)
          insert_retire_execution(store, "retire-failed", @retire_hash, :failed)
          insert_retire_execution(store, "retire-cancelled", @retire_hash, :cancelled)

          assert {:ok, _info} =
                   @conformance_adapter.retire_chart(store.opts, @retire_hash, retirement())

          assert {:error, {:chart_retired, _info}} =
                   @conformance_adapter.fetch_chart(store.opts, @retire_hash)

          refute match?(
                   {:error, :chart_not_found},
                   @conformance_adapter.fetch_chart(store.opts, @retire_hash)
                 )
        end

        # sabotage: drop the adapter under test's already-retired
        # answer - the `info = retired_info(...)` cond clause in the
        # in-memory adapter's retire_stored/4, and the zero-row branch
        # of the Ecto adapter's written/4, which is where a row its
        # conditional UPDATE declined to touch is read back -> red, the
        # second retirement answered {:ok, ...} over a chart it had not
        # written. Verified red on both conformance suites. Reverted
        # from a copy.
        test "adapter: retiring twice answers the retired arm, never a second tombstone",
             %{store: store} do
          save_retirable_chart(store, @retire_hash)
          first = DateTime.from_naive!(~N[2026-09-19 18:00:00.000000], "Etc/UTC")
          second = DateTime.from_naive!(~N[2026-09-19 19:00:00.000000], "Etc/UTC")

          assert {:ok, _info} =
                   @conformance_adapter.retire_chart(store.opts, @retire_hash, %{
                     retired_at: first,
                     retired_by: "first-operator",
                     sources: %{}
                   })

          assert {:error, {:chart_retired, info}} =
                   @conformance_adapter.retire_chart(store.opts, @retire_hash, %{
                     retired_at: second,
                     retired_by: "second-operator",
                     sources: %{}
                   })

          assert info.retired_at == first
          assert info.retired_by == "first-operator"
        end

        # sabotage: in the adapter under test's save_chart/2, drop the
        # retired check and go straight to the write -> red, the save
        # after the retirement answered :ok instead of the retired arm.
        # Verified red on both conformance suites. Reverted from a copy.
        test "adapter: saving a tombstoned hash refuses and does not revive it", %{store: store} do
          save_retirable_chart(store, @retire_hash)

          assert {:ok, _info} =
                   @conformance_adapter.retire_chart(store.opts, @retire_hash, retirement())

          assert {:error, {:chart_retired, _info}} =
                   @conformance_adapter.save_chart(store.opts, %{
                     content_hash: @retire_hash,
                     identity_blob: <<1, 2, 3>>,
                     chart_blob: <<4, 5, 6>>
                   })

          assert {:error, {:chart_retired, _info}} =
                   @conformance_adapter.fetch_chart(store.opts, @retire_hash)
        end

        # sabotage: in the adapter under test's retire_chart/3, drop the
        # nil-row clause so a hash with no chart falls through to the
        # counts -> red, an unknown hash answered {:ok, ...} (in-memory)
        # rather than :chart_not_found. Verified red on both conformance
        # suites. Reverted from a copy.
        test "adapter: a hash this store never held is a miss, not a retirement",
             %{store: store} do
          assert {:error, :chart_not_found} =
                   @conformance_adapter.retire_chart(
                     store.opts,
                     "sha256:conformance-retire-never-stored",
                     retirement()
                   )
        end

        # sabotage: in the adapter under test's
        # list_active_execution_ids_by_content_hash/2, drop the status
        # predicate -> red, the completed execution's id came back
        # beside the active one. Verified red on both conformance
        # suites. Reverted from a copy.
        test "adapter: only the :active executions on the hash are listed for a pin source",
             %{store: store} do
          save_retirable_chart(store, @retire_hash)
          insert_retire_execution(store, "retire-listed", @retire_hash, :active)
          insert_retire_execution(store, "retire-unlisted", @retire_hash, :completed)

          assert {:ok, ids} =
                   @conformance_adapter.list_active_execution_ids_by_content_hash(
                     store.opts,
                     @retire_hash
                   )

          assert ids == ["retire-listed"]
        end

        # ADR-0014 decision 4: the listing a pin source is handed stays
        # :active only; a parked execution already refuses a retirement
        # through its own count.
        #
        # sabotage: list every pinning arm (the in-memory filter reading
        # `status in @pinning_statuses`, the Ecto listing reading
        # `status in ^pinning_statuses()`) -> red on both conformance suites,
        # this case alone in each: the parked id was listed too. Verified red,
        # reverted from the copies.
        test "adapter: a parked execution is not listed for a pin source", %{store: store} do
          save_retirable_chart(store, @retire_hash)
          insert_retire_execution(store, "retire-listed-active", @retire_hash, :active)
          insert_retire_execution(store, "retire-unlisted-parked", @retire_hash, :needs_migration)

          assert {:ok, ids} =
                   @conformance_adapter.list_active_execution_ids_by_content_hash(
                     store.opts,
                     @retire_hash
                   )

          assert ids == ["retire-listed-active"]
        end

        defp retirement(sources \\ %{}) do
          %{
            retired_at: DateTime.utc_now(),
            retired_by: "conformance-operator",
            sources: sources
          }
        end

        defp save_retirable_chart(store, content_hash) do
          assert :ok =
                   @conformance_adapter.save_chart(store.opts, %{
                     content_hash: content_hash,
                     identity_blob: <<1, 2, 3>>,
                     chart_blob: <<4, 5, 6>>
                   })
        end

        defp insert_retire_execution(store, execution_id, content_hash, status) do
          assert :ok =
                   @conformance_adapter.insert_execution(store.opts, %{
                     execution_id: execution_id,
                     status: status,
                     content_hash: content_hash,
                     identity_blob: <<1, 2, 3>>,
                     position_blob: <<7, 8, 9>>,
                     failure: nil,
                     metadata: %{},
                     outcome_blob: nil
                   })
        end
      end

      # -- Adapter level: the optional tree migration unit (ADR-0015) ----
      #
      # Generated only when the adapter under test exports the optional
      # write_tree_migration/2. The unit is the contract: every write in
      # the list lands, or none does, and a re-pin rewrites the one
      # linkage key ADR-0008's 2026-09-23 Amendment sanctions and nothing
      # else of the metadata.

      if Code.ensure_loaded?(conformance_adapter) and
           function_exported?(conformance_adapter, :write_tree_migration, 2) do
        # sabotage: in the adapter under test's re-pin, write the given
        # record's metadata (%{}) instead of carrying the stored map -
        # the in-memory adapter's tree_written/2 without carry_forward/2,
        # the Ecto adapter's linkage_update/3 answering [metadata: %{}] ->
        # red on both conformance suites: the child's metadata did not
        # come back as stored with only the pin rewritten. Verified red,
        # reverted from the copies.
        test "adapter: a tree write lands every re-pin and park, the pin rewritten", %{
          store: store
        } do
          parent = insert_tree_execution(store, "tree-parent", "sha256:tree-parent-old", %{})

          child_metadata =
            if Storage.metadata_supported?(store) do
              "tree-parent"
              |> Linkage.new("pickup", 0, "sha256:tree-child-old")
              |> Linkage.to_metadata()
              |> Map.put("branch_id", "central")
            else
              %{}
            end

          child =
            insert_tree_execution(
              store,
              "tree-parent/pickup/0",
              "sha256:tree-child-old",
              child_metadata
            )

          repinned = %{
            child
            | content_hash: "sha256:tree-child-new",
              identity_blob: <<11, 12>>,
              position_blob: <<13, 14>>,
              metadata: %{}
          }

          assert :ok =
                   @conformance_adapter.write_tree_migration(store.opts, [
                     {:repin, repinned, "sha256:tree-child-new"},
                     {:park, "tree-parent"}
                   ])

          assert {:ok, stored_child} =
                   @conformance_adapter.fetch_execution(store.opts, "tree-parent/pickup/0")

          assert stored_child.content_hash == "sha256:tree-child-new"
          assert stored_child.identity_blob == <<11, 12>>
          assert stored_child.position_blob == <<13, 14>>
          assert stored_child.status == :active

          if Storage.metadata_supported?(store) do
            assert stored_child.metadata ==
                     put_in(
                       child_metadata,
                       [Linkage.reserved_key(), "content_hash"],
                       "sha256:tree-child-new"
                     )
          end

          assert {:ok, stored_parent} =
                   @conformance_adapter.fetch_execution(store.opts, "tree-parent")

          assert stored_parent == %{parent | status: :needs_migration}
        end

        # sabotage: in the adapter under test's write_tree_migration/2,
        # keep the writes made before a refusal - the in-memory adapter
        # replacing the state with the partial map, the Ecto adapter
        # skipping tree_rows_stored/2 and returning the error without
        # rollback/1 -> red on both conformance suites: the first
        # execution came back changed. Verified red, reverted from the
        # copies.
        test "adapter: a tree write that cannot land one write lands none", %{store: store} do
          first = insert_tree_execution(store, "tree-first", "sha256:tree-first-old", %{})
          repinned = %{first | content_hash: "sha256:tree-first-new", position_blob: <<21>>}

          assert {:error, :execution_not_found} =
                   @conformance_adapter.write_tree_migration(store.opts, [
                     {:repin, repinned, nil},
                     {:park, "tree-never-stored"}
                   ])

          assert {:ok, ^first} = @conformance_adapter.fetch_execution(store.opts, "tree-first")
        end

        defp insert_tree_execution(store, execution_id, content_hash, metadata) do
          record = %{
            execution_id: execution_id,
            status: :active,
            content_hash: content_hash,
            identity_blob: <<1, 2, 3>>,
            position_blob: <<7, 8, 9>>,
            failure: nil,
            metadata: metadata,
            outcome_blob: nil
          }

          assert :ok = @conformance_adapter.insert_execution(store.opts, record)

          record
        end
      end

      # The capability itself is asserted for every adapter, supporting
      # or not. A store that cannot carry a tombstone declines at open
      # and names the backend limit; what neither answer allows is a
      # constraint violation surfacing from the database as though the
      # retirement were a defect (ADR-0012 decision 6, and V07's
      # Postgres-guarded `modify/3`).
      #
      # The case branches on the same two predicates the facade does, so
      # what it proves is that each arm is reachable, not that the
      # adapter's predicate is right. Which arm a named adapter gives is
      # asserted per adapter, where the adapter is known:
      # StatifierPersistence.Storage.RetireCapabilityTest for the ones
      # this package ships and tests against.

      # sabotage: in
      # StatifierPersistence.Storage.retire_chart/3, drop the
      # chart_retirement_supported?/1 cond clause and call the adapter
      # unconditionally -> red on the declining arm: the call raised
      # UndefinedFunctionError instead of returning
      # {:error, :chart_retirement_unsupported}. Verified red on the
      # InputLogAdapter conformance suite, which is the double that
      # answers the drained query and still cannot carry a tombstone.
      # Reverted from a copy.
      test "facade: a retirement either runs or is declined at open", %{store: store} do
        answer =
          Storage.retire_chart(store, "sha256:conformance-retire-capability",
            retired_by: "conformance-operator"
          )

        cond do
          not Storage.content_hash_query_supported?(store) ->
            assert {:error, :content_hash_query_unsupported} = answer

          not Storage.chart_retirement_supported?(store) ->
            assert {:error, :chart_retirement_unsupported} = answer

          true ->
            assert {:error, :chart_not_found} = answer
        end
      end

      # -- Adapter level: the optional tombstone read (ADR-0012) ---------
      #
      # Generated only when the adapter under test exports the optional
      # fetch_retired_info/2. What these cases prove is the answer; that
      # the read leaves the chart's bytes behind is asserted per adapter,
      # where the store can be observed: the Ecto adapter's statement in
      # StatifierPersistence.Storage.EctoTest.

      if Code.ensure_loaded?(conformance_adapter) and
           function_exported?(conformance_adapter, :fetch_retired_info, 2) do
        # sabotage: in the adapter under test's fetch_retired_info/2,
        # answer {:ok, %{retired_at: DateTime.utc_now(), retired_by: nil}}
        # for every hash -> red, a live chart and a hash never stored both
        # read as retired. Verified red on both conformance suites.
        # Reverted from a copy.
        test "adapter: the tombstone read answers nil for a live chart and for a hash never stored",
             %{store: store} do
          assert :ok =
                   @conformance_adapter.save_chart(store.opts, %{
                     content_hash: "sha256:conformance-tombstone-live",
                     identity_blob: <<1, 2, 3>>,
                     chart_blob: <<4, 5, 6>>
                   })

          assert {:ok, nil} =
                   @conformance_adapter.fetch_retired_info(
                     store.opts,
                     "sha256:conformance-tombstone-live"
                   )

          assert {:ok, nil} =
                   @conformance_adapter.fetch_retired_info(
                     store.opts,
                     "sha256:conformance-tombstone-never-stored"
                   )
        end

        if function_exported?(conformance_adapter, :retire_chart, 3) do
          # sabotage: in the adapter under test's fetch_retired_info/2,
          # answer {:ok, nil} for every hash -> red, the retired hash read
          # as live. Verified red on both conformance suites. Reverted
          # from a copy.
          test "adapter: the tombstone read answers what the retired arm of fetch_chart/2 carries",
               %{store: store} do
            hash = "sha256:conformance-tombstone-retired"
            at = DateTime.from_naive!(~N[2026-09-23 09:00:00.000000], "Etc/UTC")

            assert :ok =
                     @conformance_adapter.save_chart(store.opts, %{
                       content_hash: hash,
                       identity_blob: <<1, 2, 3>>,
                       chart_blob: <<4, 5, 6>>
                     })

            assert {:ok, _info} =
                     @conformance_adapter.retire_chart(store.opts, hash, %{
                       retired_at: at,
                       retired_by: "conformance-operator",
                       sources: %{}
                     })

            assert {:error, {:chart_retired, from_fetch}} =
                     @conformance_adapter.fetch_chart(store.opts, hash)

            assert {:ok, from_read} = @conformance_adapter.fetch_retired_info(store.opts, hash)
            assert from_read == from_fetch
            assert from_read.retired_at == at
            assert from_read.retired_by == "conformance-operator"
          end
        end
      end

      # -- Adapter level: the optional execution metadata (ADR-0006) -----------
      #
      # A conformant adapter either round-trips a non-empty metadata map or
      # refuses it at open; what it must never do is accept the create and
      # silently drop the map (ADR-0006 decision 3). Both answers are
      # generated for every adapter and the assertion branches on
      # `Storage.metadata_supported?/1`, so the suite tests the answer this
      # adapter actually gives rather than only the supporting one.

      # sabotage: in StatifierPersistence.Storage.insert_execution/5, drop the
      # metadata from the built record (pass %{} instead of the validated
      # option) -> red for a supporting adapter: the fetched record's
      # metadata came back %{} instead of the two pairs. And in the same
      # function, delete the check_metadata_supported/2 clause from the
      # with-chain -> red for a non-supporting adapter: the insert returned
      # :ok instead of {:error, :metadata_unsupported}. Verified red on
      # both arms (InMemory and NoLockAdapter respectively), reverted.
      test "adapter: a non-empty metadata map either round-trips or is refused at open", %{
        store: store
      } do
        {_source, machine} = Charts.chart_a()

        machine_state =
          Statifier.MachineState.new(machine, session_id: "sess_conformance_metadata")

        metadata = %{"tenant_id" => "acct_conformance", "processor_account_id" => "pacct_4471"}

        result =
          Storage.insert_execution(
            store,
            "execution-conformance-metadata",
            machine_state,
            :active,
            metadata: metadata
          )

        if Storage.metadata_supported?(store) do
          assert :ok = result

          assert {:ok, fetched} = Storage.fetch_execution(store, "execution-conformance-metadata")
          assert fetched.metadata == metadata
        else
          assert {:error, :metadata_unsupported} = result

          # Refusal is at open, so nothing was written either.
          assert {:error, :execution_not_found} =
                   Storage.fetch_execution(store, "execution-conformance-metadata")
        end
      end

      # sabotage: in StatifierPersistence.Storage's
      # check_metadata_supported/2, delete the map_size(metadata) == 0
      # clause so every map consults the adapter -> red for a
      # non-supporting adapter: this insert returned
      # {:error, :metadata_unsupported} instead of :ok. Verified red,
      # reverted.
      test "adapter: an absent metadata map is never refused, and reads back as %{}", %{
        store: store
      } do
        {_source, machine} = Charts.chart_a()

        machine_state =
          Statifier.MachineState.new(machine, session_id: "sess_conformance_no_metadata")

        assert :ok =
                 Storage.insert_execution(
                   store,
                   "execution-conformance-no-metadata",
                   machine_state,
                   :active
                 )

        assert {:ok, fetched} =
                 Storage.fetch_execution(store, "execution-conformance-no-metadata")

        assert fetched.metadata == %{}
      end

      # sabotage: in the adapter under test's update_execution/2, write the given
      # record's metadata instead of carrying the stored map forward (for
      # the Ecto adapter, add metadata: execution_record.metadata to the set:
      # list; for InMemory, drop the Map.put that restores it) -> red, the
      # fetch below saw %{} where the created map should still be.
      # Verified red on both, reverted.
      test "adapter: metadata is write-once - an update carries the stored map forward", %{
        store: store
      } do
        if Storage.metadata_supported?(store) do
          {_source, machine} = Charts.chart_a()

          machine_state =
            Statifier.MachineState.new(machine, session_id: "sess_conformance_metadata_update")

          metadata = %{"tenant_id" => "acct_conformance_update"}

          assert :ok =
                   Storage.insert_execution(
                     store,
                     "execution-conformance-metadata-update",
                     machine_state,
                     :active,
                     metadata: metadata
                   )

          assert :ok =
                   Storage.update_execution(
                     store,
                     "execution-conformance-metadata-update",
                     machine_state,
                     :completed
                   )

          assert {:ok, fetched} =
                   Storage.fetch_execution(store, "execution-conformance-metadata-update")

          assert fetched.status == :completed
          assert fetched.metadata == metadata
        end
      end

      # -- Adapter level: the optional per-execution lock ----------------------
      #
      # Generated only when the adapter under test exports the optional
      # lock_execution/3 (ADR-0003 amendment 2026-08-22, ADR-0004 decision 5) -
      # the same shape as the isolate/1 hook: exporting the callback is
      # what opts an adapter into its contract.

      if Code.ensure_loaded?(conformance_adapter) and
           function_exported?(conformance_adapter, :lock_execution, 3) do
        # sabotage: in the adapter under test's lock_execution/3, run fun without
        # the exclusion ({:ok, fun.()} with no acquire) -> red, the two
        # sleeping bodies below interleave and the enter/enter prefix
        # breaks the paired pattern. Verified red (together with
        # ExecutionsTest's concurrent-step test under this one mutation),
        # reverted.
        @tag :postgres
        test "adapter: lock_execution/3 never overlaps two bodies for one execution_id", %{
          store: store
        } do
          {:ok, events} = Agent.start_link(fn -> [] end)

          body = fn tag ->
            fn ->
              Agent.update(events, &[{:enter, tag} | &1])
              Process.sleep(30)
              Agent.update(events, &[{:exit, tag} | &1])
              tag
            end
          end

          tasks =
            for tag <- [:first, :second] do
              Task.async(fn ->
                @conformance_adapter.lock_execution(
                  store.opts,
                  "execution-conformance-lock",
                  body.(tag)
                )
              end)
            end

          assert [{:ok, _tag_a}, {:ok, _tag_b}] = Task.await_many(tasks, 5_000)

          recorded = events |> Agent.get(& &1) |> Enum.reverse()
          assert [{:enter, one}, {:exit, one}, {:enter, other}, {:exit, other}] = recorded
          assert one != other
        end

        # sabotage: in the adapter under test's lock_execution/3, release only on
        # a normal return (move the release out of the after block, after
        # {:ok, fun.()}) -> red, the raise leaks the lock and the
        # reacquisition below times out (Task.yield returns nil). Verified
        # red, reverted.
        @tag :postgres
        test "adapter: lock_execution/3 releases the lock after a raising fun", %{store: store} do
          assert_raise RuntimeError, "lock body boom", fn ->
            @conformance_adapter.lock_execution(
              store.opts,
              "execution-conformance-lock-raise",
              fn ->
                raise "lock body boom"
              end
            )
          end

          task =
            Task.async(fn ->
              @conformance_adapter.lock_execution(
                store.opts,
                "execution-conformance-lock-raise",
                fn ->
                  :reacquired
                end
              )
            end)

          assert {:ok, {:ok, :reacquired}} = Task.yield(task, 1_000) || Task.shutdown(task)
        end
      end

      # -- Adapter level: the optional input log (ADR-0010) --------------
      #
      # Generated only when the adapter under test exports the optional
      # append_input/3 - the same opt-in-by-export shape every optional
      # callback above uses. An adapter that exports none of the three
      # stores no inputs, sees no behaviour change, and generates none of
      # these cases (ADR-0010 decision 1).
      #
      # Untagged, unlike the child enumeration and the lock: nothing here
      # needs a Postgres-only feature - no jsonb predicate, no advisory
      # lock, no index type beyond a unique one - so these cases are the
      # contract on every backend (ADR-0010 decision 9).

      if Code.ensure_loaded?(conformance_adapter) and
           function_exported?(conformance_adapter, :append_input, 3) do
        # sabotage: in the adapter under test's append_input/3, assign a
        # fixed ordinal (0) instead of the execution's next one -> red on both
        # adapters and on the SQLite mirror of this case, on the second
        # append: the in-memory one handed out 0 twice, and the Ecto one
        # returned {:adapter, :seq_conflict} off the V05 unique index.
        # Nine cases red across the two conformance modules. Verified red,
        # reverted.
        test "adapter: append_input/3 assigns dense ordinals from zero and lists them in order",
             %{store: store} do
          execution_id = input_log_execution(store, "execution-conformance-input-log")

          for {door, index} <- Enum.with_index(["create", "step", "done_invocation"]) do
            assert {:ok, ^index} =
                     @conformance_adapter.append_input(store.opts, execution_id, %{
                       execution_id: execution_id,
                       seq: 0,
                       door: door,
                       input_blob: <<index>>
                     })
          end

          assert {:ok, entries} = @conformance_adapter.list_inputs(store.opts, execution_id)

          assert Enum.map(entries, & &1.seq) == [0, 1, 2]
          assert Enum.map(entries, & &1.door) == ["create", "step", "done_invocation"]
          assert Enum.map(entries, & &1.input_blob) == [<<0>>, <<1>>, <<2>>]
        end

        # sabotage: in the adapter under test's list_inputs/2, drop the
        # execution-existence check -> red, this case asserted :execution_not_found and
        # got `{:ok, []}`. Verified red on both conformance modules and on
        # the SQLite mirror (three failures, exactly this case), reverted.
        test "adapter: list_inputs/2 reports :execution_not_found for an unknown execution_id", %{
          store: store
        } do
          assert {:error, :execution_not_found} =
                   @conformance_adapter.list_inputs(
                     store.opts,
                     "execution-conformance-absent-log"
                   )
        end

        # sabotage: in the adapter under test's list_inputs/2, return every
        # stored entry rather than the given execution's -> red on both
        # conformance modules and on the SQLite mirror: one execution's log came
        # back carrying the other's entries. Verified red, reverted.
        test "adapter: two executions' logs never see each other's entries", %{store: store} do
          execution_id = input_log_execution(store, "execution-conformance-input-log")
          other = input_log_execution(store, "execution-conformance-input-log-other")

          for door <- ["step", "step"] do
            assert {:ok, _seq} =
                     @conformance_adapter.append_input(store.opts, execution_id, %{
                       execution_id: execution_id,
                       seq: 0,
                       door: door,
                       input_blob: <<1>>
                     })
          end

          assert {:ok, 0} =
                   @conformance_adapter.append_input(store.opts, other, %{
                     execution_id: other,
                     seq: 0,
                     door: "answer_parent",
                     input_blob: <<2>>
                   })

          assert {:ok, mine} = @conformance_adapter.list_inputs(store.opts, execution_id)
          assert {:ok, theirs} = @conformance_adapter.list_inputs(store.opts, other)

          assert Enum.map(mine, & &1.seq) == [0, 1]
          assert Enum.map(theirs, &{&1.seq, &1.door}) == [{0, "answer_parent"}]
        end

        # sabotage: in the adapter under test's `:marker` arm, return
        # {:error, :input_log_full} without inserting the marker row -> red
        # on both conformance modules, on the SQLite mirror, and on
        # ExecutionsInputLogTest's cap case: the log ended one entry short and
        # its last entry was a real input rather than the nil-blob marker.
        # Verified red, reverted.
        test "adapter: a cap of n admits n - 1 inputs, then closes the log with a marker" do
          {:ok, capped} =
            Storage.new(@conformance_adapter, @conformance_adapter_opts ++ [input_log_cap: 3])

          if function_exported?(@conformance_adapter, :isolate, 1) do
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            :ok = apply(@conformance_adapter, :isolate, [capped.opts])
          end

          execution_id = input_log_execution(capped, "execution-conformance-input-log-cap")

          append = fn ->
            @conformance_adapter.append_input(capped.opts, execution_id, %{
              execution_id: execution_id,
              seq: 0,
              door: "step",
              input_blob: <<7>>
            })
          end

          assert {:ok, 0} = append.()
          assert {:ok, 1} = append.()
          assert {:error, :input_log_full} = append.()
          assert {:error, :input_log_full} = append.()

          assert {:ok, entries} = @conformance_adapter.list_inputs(capped.opts, execution_id)

          assert Enum.map(entries, &{&1.seq, &1.input_blob}) ==
                   [{0, <<7>>}, {1, <<7>>}, {2, nil}]

          # The refusal is the log's, never the execution's: the record is
          # untouched and still writable (ADR-0010 decision 5).
          assert {:ok, %{status: :active}} = Storage.fetch_execution(capped, execution_id)
        end

        # sabotage: in StatifierPersistence.Storage.append_input/4, encode
        # only the event's name instead of the whole struct -> red on both
        # conformance modules and on the SQLite mirror: the decoded entry
        # was a binary rather than the equal %Statifier.Event{},
        # caller_context and all. Verified red, reverted.
        test "facade: an event round-trips through the log equal to what was delivered", %{
          store: store
        } do
          execution_id = input_log_execution(store, "execution-conformance-input-log")

          event = %Statifier.Event{
            name: "done.invoke.call",
            type: :internal,
            data: %{"email" => "buyer@example.com"},
            invokeid: "call",
            origin: "sess_conformance_origin",
            origintype: "http://www.w3.org/TR/scxml/#SCXMLEventProcessor",
            sendid: "send-1",
            caller_context: %{"tenant" => "acme"}
          }

          assert Storage.input_log_supported?(store)
          assert {:ok, 0} = Storage.append_input(store, execution_id, :done_invocation, event)

          assert {:ok, [entry]} = Storage.list_inputs(store, execution_id)
          assert entry.seq == 0
          assert entry.door == "done_invocation"
          assert entry.event == event
        end

        # Inserts an execution for the log to hang off, since list_inputs/2 is
        # required to distinguish an empty log from an execution that is not
        # there. Called from inside each case that needs it rather than
        # from a `setup`, so nothing this template registers writes before
        # a host's own callbacks have run (see the moduledoc).
        defp input_log_execution(store, execution_id) do
          {_source, machine} = Charts.chart_a()

          machine_state =
            Statifier.MachineState.new(machine, session_id: "sess_" <> execution_id)

          :ok = Storage.insert_execution(store, execution_id, machine_state, :active)

          execution_id
        end
      end

      # -- Facade level --------------------------------------------------

      # sabotage: in StatifierPersistence.Storage.save_position/3, drop the
      # store.adapter.save_position(store.opts, position_record) call so
      # nothing is ever written -> red, load_position/3 below returns
      # {:error, :position_not_found} instead of the round-tripped state.
      # Verified red, reverted.
      test "facade: the guarded round trip: save a position and load it back", %{store: store} do
        {_source, machine} = Charts.chart_a()

        machine_state =
          Statifier.MachineState.new(machine,
            session_id: "sess_conformance_round_trip",
            datamodel: %{"count" => 1}
          )

        assert :ok = Storage.save_position(store, "sess_conformance_round_trip", machine_state)

        assert {:ok, loaded} =
                 Storage.load_position(store, "sess_conformance_round_trip", machine)

        assert loaded.configuration == machine_state.configuration
        assert loaded.datamodel == machine_state.datamodel
        assert loaded.status == machine_state.status
      end

      # sabotage: in StatifierPersistence.Storage.load_position/3, replace
      # the whole with-chain (fetch -> precheck_identity/2 ->
      # Position.from_binary/2) with a body that fetches the position
      # record and then unconditionally returns {:ok, MachineState.new(machine)},
      # skipping the identity check entirely -> red (this is the guard the
      # plan's Success Criteria names as needing to hold over every
      # adapter); this test's assertion on {:identity_mismatch, _, _} sees
      # a plain {:ok, _} instead. Verified red together with the
      # corrupt-bytes test below under this one mutation.
      test "facade: loading against a different chart revision is refused, not raised", %{
        store: store
      } do
        {_source_a, machine_a} = Charts.chart_a()
        {_source_b, machine_b} = Charts.chart_b()

        refute Identity.matches?(Machine.identity(machine_a), Machine.identity(machine_b))

        machine_state =
          Statifier.MachineState.new(machine_a, session_id: "sess_conformance_mismatch")

        assert :ok = Storage.save_position(store, "sess_conformance_mismatch", machine_state)

        assert {:error, {:identity_mismatch, expected, actual}} =
                 Storage.load_position(store, "sess_conformance_mismatch", machine_b)

        assert expected.content_hash == Machine.identity(machine_a).content_hash
        assert actual.content_hash == Machine.identity(machine_b).content_hash
      end

      # sabotage: same whole-with-chain-bypass mutation as the mismatch
      # test above -> red, this test's corrupt position_blob would stop
      # being refused; it would see {:ok, _} instead of
      # {:error, :not_a_statifier_blob}. Verified red.
      test "facade: corrupt position bytes are refused as :not_a_statifier_blob", %{
        store: store
      } do
        {_source, machine} = Charts.chart_a()
        identity = Machine.identity(machine)

        corrupt_record = %{
          session_id: "sess_conformance_corrupt",
          content_hash: identity.content_hash,
          identity_blob: Identity.to_binary(identity),
          position_blob: "not a statifier position blob"
        }

        :ok = @conformance_adapter.save_position(store.opts, corrupt_record)

        assert {:error, :not_a_statifier_blob} =
                 Storage.load_position(store, "sess_conformance_corrupt", machine)
      end

      # sabotage: in StatifierPersistence.Storage's private
      # precheck_identity/2, delete the %Machine{identity: nil} ->
      # {:error, :unidentified_chart} clause, leaving only the
      # Identity.from_binary/1 + matches?/2 clause -> red, Identity.matches?/2
      # is total and reaches the mismatch arm with a nil supplied identity,
      # so this test sees an {:identity_mismatch, _, nil} tuple instead of
      # :unidentified_chart. Verified red, reverted.
      test "facade: loading with an unidentified machine is refused as :unidentified_chart", %{
        store: store
      } do
        {_source, machine} = Charts.chart_a()

        machine_state =
          Statifier.MachineState.new(machine, session_id: "sess_conformance_unidentified")

        assert :ok =
                 Storage.save_position(store, "sess_conformance_unidentified", machine_state)

        unidentified_machine = Charts.unidentified_machine()

        assert {:error, :unidentified_chart} =
                 Storage.load_position(
                   store,
                   "sess_conformance_unidentified",
                   unidentified_machine
                 )
      end

      # sabotage: in StatifierPersistence.Storage.save_chart/3, replace the
      # store.adapter.save_chart(store.opts, chart_record) call with a bare
      # :ok that never writes -> red, the fetch_chart/2 below would return
      # {:error, :chart_not_found} instead of the saved record. Verified
      # red, reverted.
      test "facade: fetch_chart round trips a chart record saved through save_chart/3", %{
        store: store
      } do
        {source, machine} = Charts.chart_a()

        assert :ok = Storage.save_chart(store, machine, source)

        content_hash = Machine.identity(machine).content_hash
        assert {:ok, chart_record} = Storage.fetch_chart(store, content_hash)
        assert chart_record.chart_blob == source
        assert chart_record.content_hash == content_hash
      end

      # sabotage: in StatifierPersistence.Storage.save_chart/3, delete the
      # Machine.identity(machine) -> nil -> {:error, :unidentified_chart}
      # clause, falling back to a dummy identity so the write proceeds
      # anyway -> red, this test's assertion that saving is refused would
      # fail (save_chart/3 would return :ok). Verified red, reverted.
      test "facade: saving a chart for an unidentified machine is refused, and nothing is written",
           %{store: store} do
        unidentified_machine = Charts.unidentified_machine()

        assert {:error, :unidentified_chart} =
                 Storage.save_chart(store, unidentified_machine, "source bytes")
      end

      # sabotage: in StatifierPersistence.Storage.save_position/3, delete
      # the Machine.identity(machine_state.machine) -> nil -> {:error,
      # :unidentified_chart} clause, falling back to a dummy identity and
      # encoding the record with :erlang.term_to_binary/1 directly instead
      # of Position.to_binary/1 (bypassing that function's own guard too)
      # -> red, this test's assertion that saving is refused would fail,
      # and the "nothing is written" assertion below it would go red too.
      # Verified red (also broke the guarded round trip test above, since
      # every save now bypasses Position.to_binary/1), reverted.
      test "facade: saving a position for an unidentified machine is refused, and nothing is written",
           %{store: store} do
        unidentified_machine = Charts.unidentified_machine()

        machine_state =
          Statifier.MachineState.new(unidentified_machine,
            session_id: "sess_conformance_unidentified_save"
          )

        assert {:error, :unidentified_chart} =
                 Storage.save_position(
                   store,
                   "sess_conformance_unidentified_save",
                   machine_state
                 )

        assert {:error, :position_not_found} =
                 Storage.load_position(
                   store,
                   "sess_conformance_unidentified_save",
                   unidentified_machine
                 )
      end

      # The check create/4 runs at open, asserted for every adapter: the
      # narrow tombstone read when the adapter declares it, the full-row
      # fetch_chart/2 otherwise, and one answer either way. The retired
      # half runs only where the store can carry a tombstone.
      #
      # sabotage: in StatifierPersistence.Storage's private
      # chart_retired/2, make the narrow branch answer :ok whatever it
      # read -> red on both shipped adapters' suites, the retired chart
      # was let through; and, separately, make the fallback branch
      # answer :ok -> red on the NoTombstoneReadAdapter suite, which can
      # retire a chart and declares no tombstone read. Each verified red,
      # reverted from a copy.
      test "facade: the tombstone check refuses a retired chart and lets a live one through",
           %{store: store} do
        {source, machine} = Charts.chart_a()
        content_hash = Machine.identity(machine).content_hash

        assert :ok = Storage.check_chart_retired(store, machine)

        assert :ok = Storage.save_chart(store, machine, source)
        assert :ok = Storage.check_chart_retired(store, machine)

        if Storage.content_hash_query_supported?(store) and
             Storage.chart_retirement_supported?(store) do
          assert {:ok, _info} =
                   Storage.retire_chart(store, content_hash, retired_by: "conformance-operator")

          assert {:error, {:chart_retired, info}} = Storage.check_chart_retired(store, machine)
          assert {:error, {:chart_retired, ^info}} = Storage.fetch_chart(store, content_hash)
          assert info.retired_by == "conformance-operator"
        end
      end

      # Which read the check takes is pinned per adapter through the
      # facade's own adapter-call telemetry: an adapter that declares the
      # tombstone read must be asked for it and not for the whole row,
      # and one that does not is answered through fetch_chart/2.
      #
      # sabotage: in StatifierPersistence.Storage's private
      # chart_retired/2, always take the fetch_chart/2 branch -> red on
      # both shipped adapters' suites, the check called :fetch_chart.
      # Verified red, reverted from a copy.
      test "facade: the tombstone check reads the whole chart only when the adapter declares no narrow read",
           %{store: store} do
        {source, machine} = Charts.chart_a()
        assert :ok = Storage.save_chart(store, machine, source)

        test_pid = self()
        handler_id = {__MODULE__, :tombstone_read, make_ref()}

        :ok =
          :telemetry.attach(
            handler_id,
            [:statifier_persistence, :adapter, :call],
            &__MODULE__.__conformance_forward_adapter_call__/4,
            %{pid: test_pid}
          )

        try do
          assert :ok = Storage.check_chart_retired(store, machine)
        after
          :telemetry.detach(handler_id)
        end

        callbacks = collect_adapter_calls([])

        if narrow_read_declared?(store) do
          assert :fetch_retired_info in callbacks
          refute :fetch_chart in callbacks
        else
          assert :fetch_chart in callbacks
          refute :fetch_retired_info in callbacks
        end
      end

      # The telemetry handler for the case above, a named function
      # because :telemetry warns on an anonymous one. It forwards only
      # the calls made on the test's own process, so an async suite
      # running beside it adds nothing to what the case reads.
      @doc false
      def __conformance_forward_adapter_call__(_event, _measurements, metadata, %{pid: pid}) do
        if self() == pid, do: send(pid, {:adapter_call, metadata.callback})
      end

      defp narrow_read_declared?(store) do
        if function_exported?(@conformance_adapter, :supports_retired_info?, 1) and
             function_exported?(@conformance_adapter, :fetch_retired_info, 2) do
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(@conformance_adapter, :supports_retired_info?, [store.opts]) == true
        else
          false
        end
      end

      defp collect_adapter_calls(acc) do
        receive do
          {:adapter_call, callback} -> collect_adapter_calls([callback | acc])
        after
          0 -> Enum.reverse(acc)
        end
      end

      # sabotage: in the adapter under test's fetch_position/2, change the
      # not-found clause to return {:ok, a_placeholder_record} instead of
      # {:error, :position_not_found} -> red, load_position/3 below would
      # hit the placeholder's empty position_blob and return
      # {:error, :not_a_statifier_blob} rather than :position_not_found.
      # Verified red, reverted.
      test "facade: loading an unknown session id returns :position_not_found", %{store: store} do
        {_source, machine} = Charts.chart_a()

        assert {:error, :position_not_found} =
                 Storage.load_position(store, "sess_conformance_never_saved", machine)
      end
    end
  end
end
