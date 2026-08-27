defmodule StatifierPersistence.Demo.AuthorizeHandler do
  @moduledoc """
  Serves `<invoke type="myapp:authorize">` for the restart demo
  (`docs/plans/260822-sp-4an.4-restart-demo-host.md`, Phase 1), following
  the handler shape statifier's own `docs/extending.md` walks through.

  `@behaviour Statifier.Invoke.Handler`'s planning callbacks are pure: they
  return instructions, they never touch the ledger or the runtime
  themselves. `perform/2` is deliberately **not** implemented here - `ctx`
  carries `session_id`, `invoke_types`, and `invoke_handlers` only
  (`Statifier.Invoke.Handler.ctx/0`), never the ledger or the runtime a
  performer would need. `StatifierPersistence.Demo.Host` performs the
  planned instructions itself, which is exactly what a process-less host
  does and is where the idempotency-on-`invoke_id` obligation
  (`docs/extending.md`'s "At-least-once") is actually honored.
  """

  @behaviour Statifier.Invoke.Handler

  alias Statifier.Effect.Invoke

  @impl Statifier.Invoke.Handler
  def start(%Invoke{invoke_id: invoke_id, params: params}, _ctx) do
    {:ok, [{:handler, __MODULE__, {:start, invoke_id, params}}]}
  end

  @impl Statifier.Invoke.Handler
  def cancel(invoke_id, _ctx) do
    {:ok, [{:handler, __MODULE__, {:cancel, invoke_id}}]}
  end

  @impl Statifier.Invoke.Handler
  def forward(_invoke_id, _event, _ctx) do
    # This handler's jobs take no autoforwarded events.
    {:ok, []}
  end
end
