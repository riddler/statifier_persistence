defmodule StatifierPersistence.PinSource do
  @moduledoc """
  The behaviour a host implements so a pin this package cannot see still
  refuses a retirement.

  ADR-0012 decision 1 names four things that pin a content hash. Three of
  them are rows in this package's own tables and it counts them itself. The
  fourth is everything else a host knows about: a pending timer, an address
  row, a queue entry - state held outside this package, in a package this one
  does not depend on and must not learn about. A pin source is how that state
  gets a vote.

  ## The callback

  `c:pins/2` is handed a content hash and a context, and answers the source's
  own named counts as a map of atom to non-negative integer. The names are the
  source's to choose; they travel back to the caller under the source module's
  name, so a refusal says which source objected and what it was counting.

  The context carries `:execution_ids`, the ids of the `:active` executions on
  that hash, which the retire call already holds. It is there because a source
  such as a timer queue knows executions and never knows content hashes:
  handing over the ids is what lets such a source answer without learning this
  package's key. A source that does know hashes can ignore the context
  entirely.

  ## A source that cannot answer is a refusal, never a zero

  A source may raise, and raising is the supported way to say "I could not
  answer". "The source could not answer" and "the source answered zero" are
  different facts, and collapsing them would retire a pinned chart, so
  `collect/3` turns a raise into `{:error, {module, reason}}` and the
  host-facing retire door stops there rather than retiring on a count it never
  took. Returning anything that is not a map of atom to non-negative integer
  is the same kind of failure and gets the same answer.

  A source that throws, or exits - a `GenServer.call/3` that times out inside
  it is the usual case - has not answered either, and is refused the same
  way. Each failure keeps its own reason, so a host can tell them apart: see
  `t:reason/0`.

  ## This package ships no source

  There is no implementation of this behaviour in `lib/`, and `mix.exs` gains
  no dependency for one. A host passes the list of source modules in at the
  retire call, and each module is one the host owns.

  ## A migration asks too

  `StatifierPersistence.Executions.migrate/4` asks the sources a host passes
  in its `pin_sources:` option whether the one execution it migrates has a
  pending timer (ADR-0013 decision 6). It hands over the plan's `from` hash
  and that execution's id, alone, in `:execution_ids`; the execution may be
  `:active` or parked in `:needs_migration`. A source that cannot answer
  refuses the migration exactly as it refuses a retirement.

  ## Two hosts

  A durable timer queue, over an advertising chart that waits for a click
  after an impression:

      defmodule MyApp.TimerPins do
        @behaviour StatifierPersistence.PinSource

        @impl true
        def pins(_content_hash, %{execution_ids: execution_ids}) do
          %{pending_timers: MyApp.Timers.count_scheduled_for(execution_ids)}
        end
      end

  An address table, over the same chart, where an impression id is the address
  an incoming click is routed to:

      defmodule MyApp.AddressPins do
        @behaviour StatifierPersistence.PinSource

        @impl true
        def pins(content_hash, _context) do
          %{addresses: MyApp.Addresses.count_for_chart(content_hash)}
        end
      end

  Both modules are the host's. Neither is in this package, and this package
  names neither except as prose.
  """

  @typedoc """
  What a source is told besides the content hash.

  `:execution_ids` holds the ids of the `:active` executions on the hash,
  or, when a migration asks, the id of the one execution it migrates.
  """
  @type context :: %{execution_ids: [String.t()]}

  @typedoc "A source's own named counts."
  @type counts :: %{atom() => non_neg_integer()}

  @typedoc """
  Why a source did not answer.

  - `{:raised, exception}` - `pins/2` raised `exception`.
  - `{:thrown, value}` - `pins/2` threw `value`.
  - `{:exited, reason}` - `pins/2` exited with `reason`, as a
    `GenServer.call/3` that times out does.
  - `{:invalid_return, value}` - `pins/2` returned `value`, which is not a
    map of atom to non-negative integer.
  """
  @type reason ::
          {:raised, Exception.t()}
          | {:thrown, term()}
          | {:exited, term()}
          | {:invalid_return, term()}

  @doc """
  Answers this source's named counts for `content_hash`.

  Raise to refuse: a source that cannot answer must not answer zero. A throw
  or an exit refuses too.
  """
  @callback pins(content_hash :: String.t(), context :: context()) :: counts()

  @doc """
  Calls each source in order and collects its counts under its module name.

  Answers `{:ok, %{module => counts}}` when every source answered, and
  `{:error, {module, reason}}` at the first source that raised, threw, exited
  or returned anything but a map of atom to non-negative integer, where
  `reason` is `{:raised, exception}`, `{:thrown, value}`, `{:exited, reason}`
  or `{:invalid_return, value}` (`t:reason/0`). An empty source list answers
  `{:ok, %{}}`.

  The first failure stops the walk: the retirement is already refused, and the
  remaining sources' counts cannot change that.
  """
  @spec collect([module()], String.t(), context()) ::
          {:ok, %{module() => counts()}} | {:error, {module(), reason()}}
  def collect(sources, content_hash, context) when is_list(sources) do
    Enum.reduce_while(sources, {:ok, %{}}, fn source, {:ok, collected} ->
      case ask(source, content_hash, context) do
        {:ok, counts} -> {:cont, {:ok, Map.put(collected, source, counts)}}
        {:error, reason} -> {:halt, {:error, {source, reason}}}
      end
    end)
  end

  defp ask(source, content_hash, context) do
    counts = source.pins(content_hash, context)

    if valid_counts?(counts),
      do: {:ok, counts},
      else: {:error, {:invalid_return, counts}}
  rescue
    exception -> {:error, {:raised, exception}}
  catch
    :throw, value -> {:error, {:thrown, value}}
    :exit, reason -> {:error, {:exited, reason}}
  end

  defp valid_counts?(counts) do
    is_map(counts) and
      Enum.all?(counts, fn {name, count} ->
        is_atom(name) and is_integer(count) and count >= 0
      end)
  end
end
