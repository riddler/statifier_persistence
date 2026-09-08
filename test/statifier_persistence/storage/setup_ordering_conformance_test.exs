defmodule StatifierPersistence.Storage.SetupOrderingConformanceTest do
  @moduledoc """
  The setup-ordering contract in `StatifierPersistence.Testing.StorageConformance`'s
  moduledoc, under test.

  A host whose adapter needs a per-test binding established before any
  write is told to define that `setup` above the `use`. What makes that
  advice enough is the other half of the contract: nothing the template
  registers writes. This module is the host-shaped case that holds it - a
  `setup` defined BELOW the `use`, so it runs after every callback the
  template registers, which records the order it observed and asserts the
  adapter is still empty of the input-log fixture run when it is called.

  The callback is registered for the whole module, so every case the
  template generates for `StatifierPersistence.Test.InputLogAdapter` runs
  through it: the assertion is the contract over all of them, not over
  one.

  sabotage: put the eager fixture back - a
  `setup %{store: store} do %{logged_run: input_log_run(store, "run-conformance-input-log")} end`
  above the input-log cases in the template, with the three cases reading
  `logged_run` from the context again -> red here, on every case this
  module generates, with the fixture run already inserted by the time the
  host-shaped callback ran. Verified red, reverted.
  """

  use StatifierPersistence.Testing.StorageConformance,
    async: true,
    adapter: StatifierPersistence.Test.InputLogAdapter,
    opts: []

  @fixture_run "run-conformance-input-log"

  # Deliberately BELOW the `use`. This is the shape the moduledoc warns a
  # host away from when it needs a binding in place before a write, and it
  # is the shape whose one guarantee - that no row has been written yet -
  # this module exists to hold.
  setup context do
    # The template's own `setup` has already run: it is defined at the
    # `use` above, and ExUnit runs callbacks in definition order.
    assert %Storage{} = context.store

    assert {:error, :run_not_found} = Storage.fetch_run(context.store, @fixture_run)

    %{setup_order: [:template_setup, :host_setup]}
  end

  # sabotage: put the eager fixture back in the template - a
  # `setup %{store: store} do %{logged_run: input_log_run(store,
  # "run-conformance-input-log")} end` above the input-log cases -> red,
  # 38 of 38 cases in this module, the host-shaped callback finding the
  # fixture run already inserted. Verified red, reverted.
  test "a host setup below the `use` runs after the template's, and before any write",
       %{setup_order: order} do
    assert order == [:template_setup, :host_setup]
  end

  # sabotage: in the template's `input_log_run/2`, drop the
  # `Storage.insert_run(store, run_id, machine_state, :active)` -> red,
  # this case plus the four input-log cases that build the fixture, all
  # reporting `:run_not_found` where a run was expected. Verified red,
  # reverted.
  test "the input-log fixture lands only when a case builds it", %{store: store} do
    assert {:error, :run_not_found} = Storage.fetch_run(store, @fixture_run)

    run_id = input_log_run(store, @fixture_run)

    assert {:ok, %{status: :active}} = Storage.fetch_run(store, run_id)
  end
end
