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
        "content_hash" => "sha256:..."
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

  `child_index` is `0` for every child this version creates. It is
  recorded anyway because ADR-0008 decision 7 requires the linkage not to
  *assume* one child per invocation; nothing here fans out.
  """

  alias StatifierPersistence.Storage.Adapter

  @enforce_keys [:parent_run_id, :invoke_id, :child_index, :content_hash]
  defstruct [:parent_run_id, :invoke_id, :child_index, :content_hash]

  @type t :: %__MODULE__{
          parent_run_id: Adapter.run_id(),
          invoke_id: String.t(),
          child_index: non_neg_integer(),
          content_hash: Adapter.content_hash()
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
  The reserved-namespace metadata map for `linkage`, string keys and
  JSON-representable values only, so the Ecto adapter's `jsonb` check
  passes and the map is safe to merge into a `metadata:` option unchanged.
  """
  @spec to_metadata(t()) :: Adapter.metadata()
  def to_metadata(%__MODULE__{} = linkage) do
    %{
      reserved_key() => %{
        "parent_run_id" => linkage.parent_run_id,
        "invoke_id" => linkage.invoke_id,
        "child_index" => linkage.child_index,
        "content_hash" => linkage.content_hash
      }
    }
  end

  @doc """
  Reads a linkage back out of a stored run's `metadata`.

  `:no_linkage` for a run whose metadata carries none - a `%{}` metadata
  map, a host map with unrelated keys, or an adapter that does not store
  metadata at all. Not an `{:error, _}`: having no parent is an ordinary
  property of a run, not a failure, and every run this package has ever
  created before this feature has none.
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
       }} ->
        {:ok, new(parent_run_id, invoke_id, child_index, content_hash)}

      _absent_or_malformed ->
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
