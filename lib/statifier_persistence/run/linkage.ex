defmodule StatifierPersistence.Run.Linkage do
  @moduledoc """
  A durable subchart child's parent linkage: the reserved, package-owned
  namespace inside a run's `metadata` (ADR-0008 decision 2).

  ADR-0006 decision 1 says this package never reads a metadata key to make
  a decision. ADR-0008 decision 2 narrows that, and narrows it exactly
  this far: linkage lives under one reserved top-level key -
  `"statifier_persistence"`, this module's `reserved_key/0` - this package
  reads *only* that key, and everything outside it stays as opaque as it
  was: never read, never validated beyond shape, never merged into a blob.
  ADR-0006 decision 2 is untouched: every value here is an identity (a run
  id, an invocation id, a content hash) and never personal data.

  The stored shape, under the reserved key:

      %{
        "parent_run_id" => "run_42",
        "invoke_id" => "call",
        "child_index" => 0,
        "content_hash" => "sha256:...",
        # fan-out only, both absent otherwise
        "child_count" => 3,
        "policy" => "all"
      }

  `content_hash` is the **mandatory** pin ADR-0008 decision 2 hardens into
  contract: the same hash `Statifier.Machine.identity/1` produces for the
  child's own chart, recorded a second time where the parent-child
  relationship can see it. A child is resumed by whatever node picks it up,
  and this is what stands between "resumed the workflow you started" and
  "resumed a different workflow that happens to share an id" - without the
  pin, a reused or collided run id would let a node silently guard a
  child's own load against the wrong chart's identity while still
  believing it is answering the right parent.

  `child_index` is the child's position in the list its invocation fanned
  out over: `0` for an ordinary durable subchart, `0..child_count - 1` for
  a fan-out. It is durably on the child rather than held by whatever
  started it, which is what lets a completion arriving on a node that has
  never seen the parent live be placed at its index (ADR-0008's sp-3n2
  amendment, point 2).

  ## The two fan-out values

  `child_count` and `policy` are the amendment's ordered set expressed
  per-child: N, and how the invocation aggregates its N answers - `:all`
  waits for every child, `:first_error` cancels the rest as soon as one
  fails. Both are **absent** from the stored map for an ordinary durable
  subchart, and absence is the discriminator `fan_out?/1` reads: a child
  with no `child_count` answers its parent's door directly, exactly as
  every child created before this feature does, and its stored metadata is
  byte-identical to what that path has always written.

  `child_count: 1` is therefore not "not a fan-out". It is the N=1 fan-out
  the amendment's point 3 names - one shape read at N=1 or at N=1000 -
  and it settles through the same path a larger one does.

  Both values are identities in ADR-0006 decision 2's sense: a count and a
  constant, never personal data.
  """

  alias StatifierPersistence.Storage.Adapter

  @typedoc """
  How an invocation aggregates its children's answers (statifier_blocks
  ADR-0009 decision 6): `:all` waits for every child, `:first_error`
  cancels the remaining ones as soon as one fails.
  """
  @type policy :: :all | :first_error

  @policies %{"all" => :all, "first_error" => :first_error}
  @policy_strings %{all: "all", first_error: "first_error"}

  @enforce_keys [:parent_run_id, :invoke_id, :child_index, :content_hash]
  defstruct [
    :parent_run_id,
    :invoke_id,
    :child_index,
    :content_hash,
    child_count: nil,
    policy: nil
  ]

  @type t :: %__MODULE__{
          parent_run_id: Adapter.run_id(),
          invoke_id: String.t(),
          child_index: non_neg_integer(),
          content_hash: Adapter.content_hash(),
          child_count: pos_integer() | nil,
          policy: policy() | nil
        }

  @typedoc "The reserved top-level metadata key this module owns."
  @type reserved_key :: String.t()

  @doc """
  The one definition site for the reserved metadata namespace.
  """
  @spec reserved_key() :: reserved_key()
  def reserved_key, do: "statifier_persistence"

  @doc """
  Builds a linkage struct from its four values. Does not derive a child run
  id and does not touch storage - `child_run_id/3` and `to_metadata/1` do
  that separately, so a caller that only needs the id shape never has to
  fabricate a `content_hash` it does not yet have.
  """
  @spec new(
          parent_run_id :: Adapter.run_id(),
          invoke_id :: String.t(),
          child_index :: non_neg_integer(),
          content_hash :: Adapter.content_hash()
        ) :: t()
  def new(parent_run_id, invoke_id, child_index, content_hash)
      when is_binary(parent_run_id) and is_binary(invoke_id) and
             is_integer(child_index) and child_index >= 0 and is_binary(content_hash) do
    %__MODULE__{
      parent_run_id: parent_run_id,
      invoke_id: invoke_id,
      child_index: child_index,
      content_hash: content_hash
    }
  end

  @doc """
  `new/4`'s fan-out form: the same four values plus the invocation's
  `child_count` and its aggregation `policy`.

  `child_index` must be inside `0..child_count - 1`; anything else is a
  caller bug rather than a storage event, so it raises `ArgumentError` the
  way a malformed writer option does elsewhere in this package.
  """
  @spec new(
          parent_run_id :: Adapter.run_id(),
          invoke_id :: String.t(),
          child_index :: non_neg_integer(),
          content_hash :: Adapter.content_hash(),
          child_count :: pos_integer(),
          policy :: policy()
        ) :: t()
  def new(parent_run_id, invoke_id, child_index, content_hash, child_count, policy)
      when is_integer(child_count) and child_count > 0 and is_map_key(@policy_strings, policy) do
    if child_index >= child_count do
      raise ArgumentError,
            "child_index #{child_index} is outside 0..#{child_count - 1} " <>
              "for a fan-out of #{child_count}"
    end

    %{
      new(parent_run_id, invoke_id, child_index, content_hash)
      | child_count: child_count,
        policy: policy
    }
  end

  @doc """
  Whether this linkage's child is one of a fan-out's N.

  The discriminator is the presence of `child_count`, not its value:
  `child_count: 1` is the N=1 fan-out (ADR-0008's sp-3n2 amendment, point
  3) and answers `true`, while an ordinary durable subchart carries no
  count at all and answers `false`.
  """
  @spec fan_out?(t()) :: boolean()
  def fan_out?(%__MODULE__{child_count: nil}), do: false
  def fan_out?(%__MODULE__{}), do: true

  @doc """
  The reserved-namespace metadata map for `linkage`, string keys and
  JSON-representable values only, so the Ecto adapter's `jsonb` check
  passes and the map is safe to merge into a `metadata:` option unchanged.

  `child_count` and `policy` appear only for a fan-out child, so a
  non-fan-out linkage produces exactly the four-key map this function has
  always produced.
  """
  @spec to_metadata(t()) :: Adapter.metadata()
  def to_metadata(%__MODULE__{} = linkage) do
    base = %{
      "parent_run_id" => linkage.parent_run_id,
      "invoke_id" => linkage.invoke_id,
      "child_index" => linkage.child_index,
      "content_hash" => linkage.content_hash
    }

    %{reserved_key() => Map.merge(base, fan_out_metadata(linkage))}
  end

  @spec fan_out_metadata(t()) :: %{optional(String.t()) => term()}
  defp fan_out_metadata(%__MODULE__{child_count: nil}), do: %{}

  defp fan_out_metadata(%__MODULE__{child_count: child_count, policy: policy}) do
    %{"child_count" => child_count, "policy" => Map.fetch!(@policy_strings, policy)}
  end

  @doc """
  Reads a linkage back out of a stored run's `metadata`.

  `:no_linkage` for a run whose metadata carries none - a `%{}` metadata
  map, a host map with unrelated keys, or an adapter that does not store
  metadata at all. Not an `{:error, _}`: having no parent is an ordinary
  property of a run, not a failure, and every run this package has ever
  created before this feature has none.

  The two fan-out values are read when present. A reserved map carrying
  one of them without the other, a `child_count` that is not a positive
  integer, a `child_index` outside `0..child_count - 1`, or a `policy`
  that is neither spelling is malformed rather than partially readable,
  and answers `:no_linkage` - the same arm every other malformed reserved
  map takes.
  """
  @spec from_metadata(Adapter.metadata()) :: {:ok, t()} | :no_linkage
  def from_metadata(metadata) when is_map(metadata) do
    case Map.fetch(metadata, reserved_key()) do
      {:ok,
       %{
         "parent_run_id" => parent_run_id,
         "invoke_id" => invoke_id,
         "child_index" => child_index,
         "content_hash" => content_hash
       } = reserved} ->
        build(parent_run_id, invoke_id, child_index, content_hash, reserved)

      _absent_or_malformed ->
        :no_linkage
    end
  end

  # The fan-out half is optional and all-or-nothing: neither key present
  # is an ordinary durable subchart, both present and well-formed is a
  # fan-out child, and anything else is malformed.
  @spec build(term(), term(), term(), term(), map()) :: {:ok, t()} | :no_linkage
  defp build(parent_run_id, invoke_id, child_index, content_hash, reserved) do
    case {Map.fetch(reserved, "child_count"), Map.fetch(reserved, "policy")} do
      {:error, :error} ->
        {:ok, new(parent_run_id, invoke_id, child_index, content_hash)}

      {{:ok, child_count}, {:ok, policy}} ->
        fan_out(parent_run_id, invoke_id, child_index, content_hash, child_count, policy)

      _one_without_the_other ->
        :no_linkage
    end
  rescue
    # `new/4`'s and `new/6`'s guards are the shape check; a stored map that
    # fails one is malformed metadata, not a caller bug, so it takes the
    # same `:no_linkage` arm rather than raising into a fetch.
    FunctionClauseError -> :no_linkage
    ArgumentError -> :no_linkage
  end

  @spec fan_out(term(), term(), term(), term(), term(), term()) :: {:ok, t()} | :no_linkage
  defp fan_out(parent_run_id, invoke_id, child_index, content_hash, child_count, policy) do
    case Map.fetch(@policies, policy) do
      {:ok, policy} ->
        {:ok, new(parent_run_id, invoke_id, child_index, content_hash, child_count, policy)}

      :error ->
        :no_linkage
    end
  end

  @doc """
  Derives a child run id from its parent and invocation - the single
  definition site of the id shape (see the plan's "Implementation
  Approach"):

      parent_run_id <> "/" <> invoke_id <> "/" <> Integer.to_string(child_index)

  Deterministic in every input, which buys idempotency across ADR-0004
  decision 3's at-least-once re-drive: the same crash-and-retry recomputes
  the same id, so the adapter's atomic `:run_exists` refusal is what
  answers the re-drive rather than a second child being created. The
  result strictly extends `parent_run_id` as a string, which is the
  acyclicity property the cascade in Phase 5 rests on: no run can be its
  own descendant, because every descendant's id is strictly longer than
  its ancestor's.
  """
  @spec child_run_id(
          parent_run_id :: Adapter.run_id(),
          invoke_id :: String.t(),
          child_index :: non_neg_integer()
        ) :: Adapter.run_id()
  def child_run_id(parent_run_id, invoke_id, child_index)
      when is_binary(parent_run_id) and is_binary(invoke_id) and
             is_integer(child_index) and child_index >= 0 do
    parent_run_id <> "/" <> invoke_id <> "/" <> Integer.to_string(child_index)
  end

  @doc """
  The containment map a cascade queries `Storage.list_runs_by_metadata/2`
  with to find every child of `parent_run_id`, whatever invocation started
  it and whatever its `child_index`.
  """
  @spec parent_match(parent_run_id :: Adapter.run_id()) :: Adapter.metadata()
  def parent_match(parent_run_id) when is_binary(parent_run_id) do
    %{reserved_key() => %{"parent_run_id" => parent_run_id}}
  end

  @doc """
  The same containment map, narrowed to one invocation - what a cancel of a
  single invocation walks, rather than every child a parent has ever
  started.
  """
  @spec invocation_match(parent_run_id :: Adapter.run_id(), invoke_id :: String.t()) ::
          Adapter.metadata()
  def invocation_match(parent_run_id, invoke_id)
      when is_binary(parent_run_id) and is_binary(invoke_id) do
    %{reserved_key() => %{"parent_run_id" => parent_run_id, "invoke_id" => invoke_id}}
  end
end
