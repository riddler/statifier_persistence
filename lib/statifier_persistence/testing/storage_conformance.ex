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

  The optional run `metadata` map (ADR-0006) is treated differently again:
  its cases are generated for every adapter and assert the answer this
  adapter gives - a round trip when it declares support through
  `c:StatifierPersistence.Storage.Adapter.supports_metadata?/1`, a
  `{:error, :metadata_unsupported}` refusal at open when it does not.
  Refusing is conformance; silently dropping the map is not, and that is
  the failure these cases exist to catch.

  The optional `c:StatifierPersistence.Storage.Adapter.lock_run/3` gets the
  same treatment at generation time: when the adapter under test exports
  it, the suite generates the per-run lock tests (mutual exclusion of two
  concurrent bodies, release after a raising fun); when it does not, they
  are not generated at all - exporting the callback is what opts an
  adapter into its contract.
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

      # -- Adapter level: run records ------------------------------------

      # sabotage: in the adapter under test's insert_run/2, store under a
      # fixed key instead of run_id -> red, fetch_run/2 below returned
      # {:error, :run_not_found} instead of the round-tripped record.
      # Verified red, reverted.
      test "adapter: round-trips an inserted run byte-identically", %{store: store} do
        run_record = %{
          run_id: "run-conformance-a",
          status: :active,
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<9, 0, 8, 255, 7>>,
          position_blob: <<0, 255, 1, 2, 3, 0, 0, 254>>,
          failure: nil,
          metadata: %{}
        }

        assert :ok = @conformance_adapter.insert_run(store.opts, run_record)

        assert {:ok, ^run_record} =
                 @conformance_adapter.fetch_run(store.opts, "run-conformance-a")
      end

      # sabotage: in the adapter under test's insert_run/2, drop the
      # exists-check and always write with :ok -> red, the second insert
      # below returned :ok instead of {:error, :run_exists}. Verified red
      # (together with InMemoryTest's concurrent-insert test under this one
      # mutation), reverted.
      test "adapter: insert_run/2 refuses a duplicate run_id with :run_exists", %{store: store} do
        run_record = %{
          run_id: "run-conformance-duplicate",
          status: :active,
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: <<7, 8, 9>>,
          failure: nil,
          metadata: %{}
        }

        assert :ok = @conformance_adapter.insert_run(store.opts, run_record)

        assert {:error, :run_exists} =
                 @conformance_adapter.insert_run(store.opts, %{run_record | status: :failed})

        assert {:ok, ^run_record} =
                 @conformance_adapter.fetch_run(store.opts, "run-conformance-duplicate")
      end

      # sabotage: in the adapter under test's update_run/2, upsert on a
      # missing run_id (write and return :ok) instead of refusing -> red,
      # the update below returned :ok instead of {:error, :run_not_found}.
      # Verified red, reverted.
      test "adapter: update_run/2 reports :run_not_found for an unknown run_id", %{store: store} do
        run_record = %{
          run_id: "run-conformance-update-missing",
          status: :failed,
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: nil,
          failure: "abandoned",
          metadata: %{}
        }

        assert {:error, :run_not_found} =
                 @conformance_adapter.update_run(store.opts, run_record)

        assert {:error, :run_not_found} =
                 @conformance_adapter.fetch_run(store.opts, "run-conformance-update-missing")
      end

      # sabotage: in the adapter under test's fetch_run/2, return
      # {:ok, a_placeholder_record} instead of :run_not_found for an
      # unknown id -> red, this test's pattern match on
      # {:error, :run_not_found} saw the placeholder. Verified red,
      # reverted.
      test "adapter: fetch_run/2 reports :run_not_found for an unknown run_id", %{store: store} do
        assert {:error, :run_not_found} =
                 @conformance_adapter.fetch_run(store.opts, "run-conformance-missing")
      end

      # sabotage: in the adapter under test's insert_run/2, normalize a nil
      # position_blob to <<>> before storing -> red, the equality assertion
      # on nil below saw "" instead. This is the arm ADR-0004 decision 1
      # makes nullable; an adapter must not paper over it. Verified red,
      # reverted.
      test "adapter: a nil position_blob round-trips as nil", %{store: store} do
        run_record = %{
          run_id: "run-conformance-nil-blob",
          status: :failed,
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: nil,
          failure: "budget_exhausted: 100 rounds",
          metadata: %{}
        }

        assert :ok = @conformance_adapter.insert_run(store.opts, run_record)

        assert {:ok, fetched} =
                 @conformance_adapter.fetch_run(store.opts, "run-conformance-nil-blob")

        assert fetched.position_blob == nil
      end

      # sabotage: in the adapter under test's update_run/2, keep the stored
      # record's status and failure instead of overwriting them (a partial
      # update) -> red, the fetch below returned the inserted :active/nil
      # pair instead of the updated :failed/reason pair. Verified red,
      # reverted.
      test "adapter: update_run/2 overwrites the full record, status and failure verbatim", %{
        store: store
      } do
        inserted = %{
          run_id: "run-conformance-overwrite",
          status: :active,
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: <<7, 8, 9>>,
          failure: nil,
          metadata: %{}
        }

        updated = %{
          inserted
          | status: :failed,
            position_blob: <<10, 11, 12>>,
            failure: "abandoned: operator request"
        }

        assert :ok = @conformance_adapter.insert_run(store.opts, inserted)
        assert :ok = @conformance_adapter.update_run(store.opts, updated)

        assert {:ok, ^updated} =
                 @conformance_adapter.fetch_run(store.opts, "run-conformance-overwrite")
      end

      # sabotage: in StatifierPersistence.Storage.Ecto's @statuses list,
      # drop the cancelled: "cancelled" entry -> red,
      # encode_status(:cancelled) has no matching clause and this test's
      # insert raises FunctionClauseError instead of storing the record.
      # Verified red on the Ecto conformance suite, reverted.
      test "adapter: a :cancelled run round-trips through insert_run/2 and update_run/2 with its position untouched",
           %{store: store} do
        inserted = %{
          run_id: "run-conformance-cancelled",
          status: :cancelled,
          content_hash: "sha256:conformance-chart-a",
          identity_blob: <<1, 2, 3>>,
          position_blob: <<7, 8, 9>>,
          failure: nil,
          metadata: %{}
        }

        assert :ok = @conformance_adapter.insert_run(store.opts, inserted)

        assert {:ok, ^inserted} =
                 @conformance_adapter.fetch_run(store.opts, "run-conformance-cancelled")

        updated = %{inserted | status: :cancelled}
        assert :ok = @conformance_adapter.update_run(store.opts, updated)

        assert {:ok, fetched} =
                 @conformance_adapter.fetch_run(store.opts, "run-conformance-cancelled")

        assert fetched.status == :cancelled
        assert fetched.position_blob == inserted.position_blob
      end

      # -- Adapter level: the optional child enumeration (ADR-0008) -----
      #
      # Generated only when the adapter under test exports the optional
      # list_runs_by_metadata/2 - the same opt-in-by-export shape lock_run/3
      # gets above.

      if Code.ensure_loaded?(conformance_adapter) and
           function_exported?(conformance_adapter, :list_runs_by_metadata, 2) do
        # sabotage: in StatifierPersistence.Storage.InMemory's private
        # contains?/2, drop the is_map/is_map guarded clause that recurses
        # into a nested map value, leaving only the plain == comparison ->
        # red, the nested-match assertion below found no runs instead of
        # the one whose nested map contains the given pair. Verified red on
        # the InMemory conformance suite, reverted.
        test "adapter: list_runs_by_metadata/2 matches a nested map by containment and excludes the rest",
             %{store: store} do
          linked = %{
            run_id: "run-conformance-child-linked",
            status: :active,
            content_hash: "sha256:conformance-chart-a",
            identity_blob: <<1, 2, 3>>,
            position_blob: <<7, 8, 9>>,
            failure: nil,
            metadata: %{
              "statifier_persistence" => %{
                "parent_run_id" => "run-conformance-parent",
                "invoke_id" => "call"
              }
            }
          }

          other_parent = %{
            linked
            | run_id: "run-conformance-child-other-parent",
              metadata: %{
                "statifier_persistence" => %{
                  "parent_run_id" => "run-conformance-other-parent",
                  "invoke_id" => "call"
                }
              }
          }

          unrelated = %{linked | run_id: "run-conformance-unrelated", metadata: %{}}

          assert :ok = @conformance_adapter.insert_run(store.opts, linked)
          assert :ok = @conformance_adapter.insert_run(store.opts, other_parent)
          assert :ok = @conformance_adapter.insert_run(store.opts, unrelated)

          assert {:ok, matches} =
                   @conformance_adapter.list_runs_by_metadata(store.opts, %{
                     "statifier_persistence" => %{"parent_run_id" => "run-conformance-parent"}
                   })

          assert Enum.map(matches, & &1.run_id) == ["run-conformance-child-linked"]
        end
      end

      # -- Adapter level: the optional run metadata (ADR-0006) -----------
      #
      # A conformant adapter either round-trips a non-empty metadata map or
      # refuses it at open; what it must never do is accept the create and
      # silently drop the map (ADR-0006 decision 3). Both answers are
      # generated for every adapter and the assertion branches on
      # `Storage.metadata_supported?/1`, so the suite tests the answer this
      # adapter actually gives rather than only the supporting one.

      # sabotage: in StatifierPersistence.Storage.insert_run/5, drop the
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
          Storage.insert_run(store, "run-conformance-metadata", machine_state, :active,
            metadata: metadata
          )

        if Storage.metadata_supported?(store) do
          assert :ok = result

          assert {:ok, fetched} = Storage.fetch_run(store, "run-conformance-metadata")
          assert fetched.metadata == metadata
        else
          assert {:error, :metadata_unsupported} = result

          # Refusal is at open, so nothing was written either.
          assert {:error, :run_not_found} =
                   Storage.fetch_run(store, "run-conformance-metadata")
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
                 Storage.insert_run(store, "run-conformance-no-metadata", machine_state, :active)

        assert {:ok, fetched} = Storage.fetch_run(store, "run-conformance-no-metadata")
        assert fetched.metadata == %{}
      end

      # sabotage: in the adapter under test's update_run/2, write the given
      # record's metadata instead of carrying the stored map forward (for
      # the Ecto adapter, add metadata: run_record.metadata to the set:
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
                   Storage.insert_run(
                     store,
                     "run-conformance-metadata-update",
                     machine_state,
                     :active,
                     metadata: metadata
                   )

          assert :ok =
                   Storage.update_run(
                     store,
                     "run-conformance-metadata-update",
                     machine_state,
                     :completed
                   )

          assert {:ok, fetched} = Storage.fetch_run(store, "run-conformance-metadata-update")
          assert fetched.status == :completed
          assert fetched.metadata == metadata
        end
      end

      # -- Adapter level: the optional per-run lock ----------------------
      #
      # Generated only when the adapter under test exports the optional
      # lock_run/3 (ADR-0003 amendment 2026-08-22, ADR-0004 decision 5) -
      # the same shape as the isolate/1 hook: exporting the callback is
      # what opts an adapter into its contract.

      if Code.ensure_loaded?(conformance_adapter) and
           function_exported?(conformance_adapter, :lock_run, 3) do
        # sabotage: in the adapter under test's lock_run/3, run fun without
        # the exclusion ({:ok, fun.()} with no acquire) -> red, the two
        # sleeping bodies below interleave and the enter/enter prefix
        # breaks the paired pattern. Verified red (together with
        # RunsTest's concurrent-step test under this one mutation),
        # reverted.
        test "adapter: lock_run/3 never overlaps two bodies for one run_id", %{store: store} do
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
                @conformance_adapter.lock_run(store.opts, "run-conformance-lock", body.(tag))
              end)
            end

          assert [{:ok, _tag_a}, {:ok, _tag_b}] = Task.await_many(tasks, 5_000)

          recorded = events |> Agent.get(& &1) |> Enum.reverse()
          assert [{:enter, one}, {:exit, one}, {:enter, other}, {:exit, other}] = recorded
          assert one != other
        end

        # sabotage: in the adapter under test's lock_run/3, release only on
        # a normal return (move the release out of the after block, after
        # {:ok, fun.()}) -> red, the raise leaks the lock and the
        # reacquisition below times out (Task.yield returns nil). Verified
        # red, reverted.
        test "adapter: lock_run/3 releases the lock after a raising fun", %{store: store} do
          assert_raise RuntimeError, "lock body boom", fn ->
            @conformance_adapter.lock_run(store.opts, "run-conformance-lock-raise", fn ->
              raise "lock body boom"
            end)
          end

          task =
            Task.async(fn ->
              @conformance_adapter.lock_run(store.opts, "run-conformance-lock-raise", fn ->
                :reacquired
              end)
            end)

          assert {:ok, {:ok, :reacquired}} = Task.yield(task, 1_000) || Task.shutdown(task)
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
