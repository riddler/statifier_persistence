# How to encrypt the blob columns and place host columns

This guide shows you how to do two things the Ecto adapter lets you decide
when you configure the persistence module: encrypt the payload blob columns
at rest, and put a column of your own at a fixed position in every table the
migrations helper creates. The example is a library loan: one execution per
loan of a copy to a patron, whose events can carry the patron's contact
details, and a branch id that every table should carry as its second column.
Both parts assume a persistence module and a store built as in [How to set up
the Ecto adapter](ecto-adapter.md).

## Encrypt the blob columns

`use StatifierPersistence.Ecto` hard-codes `:binary` for its payload blob
columns (`identity_blob`, `chart_blob`, `position_blob`, `outcome_blob`, and
the input log's `input_blob`) by default - plain `bytea`, byte-identical round
trip, nothing extra. Pass `:blob_type` to put a custom Ecto type on those
columns instead, and encryption at rest needs no wrapping adapter.

### Pass a type as `:blob_type`

    defmodule MyApp.Persistence do
      use StatifierPersistence.Ecto,
        repo: MyApp.Repo,
        blob_type: MyApp.EncryptedBlob
    end

`:blob_type` accepts a bare module implementing `Ecto.Type`, or a
`{module, opts}` tuple for an `Ecto.ParameterizedType`. It reaches only
those payload columns: keys and lookup columns (`content_hash`,
`session_id`, `execution_id`, `status`, `failure`, and the input log's `seq`
and `door`) always stay plain, because the identity guard, the unique
indexes and the log's ordering depend on reading them back verbatim.

### Write the type

The shape a production `MyApp.EncryptedBlob` needs is a vault-backed or
envelope-encrypting `Ecto.Type` - `dump/1` encrypts on the way in, `load/1`
decrypts on the way out. This package takes no position on which
key-management scheme backs it; that choice belongs to the host. To prove the
shape without any encryption dependency, here is a minimal `Ecto.Type` that
reversibly transforms every byte (not encryption - a stand-in to show the
wiring):

    defmodule MyApp.ReversibleBlob do
      use Ecto.Type

      @mask 0xA5

      def type, do: :binary
      def cast(binary) when is_binary(binary), do: {:ok, binary}
      def cast(_other), do: :error
      def dump(binary) when is_binary(binary), do: {:ok, transform(binary)}
      def dump(_other), do: :error
      def load(binary) when is_binary(binary), do: {:ok, transform(binary)}
      def load(_other), do: :error

      defp transform(binary) do
        for <<byte <- binary>>, into: <<>>, do: <<Bitwise.bxor(byte, @mask)>>
      end
    end

### Check the column's database type

The shipped migrations always emit `:binary` (`bytea`) for the payload blob
columns and do not read `:blob_type`. A `:blob_type` whose underlying database
type is still binary - an envelope-encrypting type that dumps to and loads
from raw bytes, like the sketch above - needs no DDL change. A `:blob_type`
that dumps to a different underlying type (text, jsonb, a Postgres domain)
needs you to alter those columns yourself; the migrations helper does not do
it for you.

### Know what `position_blob` holds

`position_blob` holds one value that matters in particular. It carries every
`_ioprocessors` entry the execution's registered send types answered when it
was created, in the clear unless `:blob_type` encrypts, and a location
statifier_router's Basic HTTP processor hands out, with its bearer token, is
one of them. Ecto's query telemetry event carries the bound blob on every
create and every step, which Ecto's own `:debug` log line cuts at the inspect
limit, so the token is not readable there but is not absent: a raised inspect
limit, or a telemetry handler that logs `params`, prints it. The mitigations
are the host's: an encrypting `:blob_type`, never `:debug` query logging in
production, and rotating a location that may have leaked. Whether the
execution writes should take a statement-level log option is not decided.
ADR-0004's 2026-10-04 Note records the trade, and
`test/statifier_persistence/ecto/position_blob_at_rest_test.exs` pins the
entries' presence in the blob.

## Place a host column at a fixed position

Postgres appends any column an `ALTER TABLE` adds, so a host that wants a
column of its own at a fixed ordinal position on every table - a branch
column at position 2, say - cannot get it by altering the tables afterwards.

### Pass `:leading_columns`

Pass `:leading_columns` and the migrations helper puts the columns there when
it creates the tables:

    defmodule MyApp.Persistence do
      use StatifierPersistence.Ecto,
        repo: MyApp.Repo,
        leading_columns: [branch_id: {:text, null: true}]
    end

Each entry is `name: {type, opts}`, the arguments `Ecto.Migration.add/3`
takes. V01 and V05 emit the columns immediately after `id`, in the order
given, in every table they create - `charts`, `positions`, `executions` and
`inputs` - so `branch_id` above sits at ordinal position 2 on all four. No
other version touches them.

### Know what the option does

The option only places the column:

- **It applies to a fresh create.** The columns exist only in tables V01 and
  V05 create under the option. A table that already exists keeps the columns
  it has, and adding the option later changes nothing there - including on a
  database built before `0.12.0`, whose tables V06 renamed in place rather
  than re-creating them.
- **Defaults and `NOT NULL` belong to a later migration of your own.** This
  package's inserts never name the column (below), so a `NOT NULL` without a
  default that holds for every insert fails every write the package makes.
  Declare the column nullable here, then give it its default and its
  `NOT NULL` in your next migration with `ALTER COLUMN ... SET DEFAULT` and
  `ALTER COLUMN ... SET NOT NULL`, which keep it where it is. Re-adding it
  with `ADD COLUMN` would move it to the end, and evaluate its default there
  and then to fill the existing rows - an expression such as
  `current_setting(...)` would have to resolve inside that migration.
- **The package never writes it.** The generated schemas do not declare the
  column, so every row this package inserts leaves it to the column's default
  - `NULL` until you set one. The one read is a prune you confine to a
  partition with `scope:` on `StatifierPersistence.Retention.prune/3`
  ([pruning one partition](../retention.md#pruning-one-partition)).

### Place the timestamps and set collations

Two more options exist for a host that wrote these tables by hand and wants
the helper to build exactly what it wrote:

    defmodule MyApp.Persistence do
      use StatifierPersistence.Ecto,
        repo: MyApp.Repo,
        leading_columns: [branch_id: {:text, null: true}],
        timestamps_position: :leading,
        column_collations: [execution_id: "C"]
    end

- **`timestamps_position: :leading`** puts `inserted_at` and `updated_at`
  immediately after the leading columns - after `id` when there are none - in
  every table V01 and V05 create, instead of last. The default, `:trailing`,
  is the layout this package has always built. A column a later version adds
  (`metadata`, `outcome_blob`, `retired_at`, `retired_by`, `ended_at`) lands
  at the end either way.
- **`column_collations: [name: collation]`** declares that package column
  with that collation wherever V01 or V05 creates it: above, `execution_id`
  is `COLLATE "C"` on both the executions and the inputs table. The names it
  takes are the text columns those two versions declare - `content_hash`,
  `session_id`, `execution_id`, `status`, `failure` and `door` - and the
  collation must be one your database knows. A column of your own takes its
  collation in its `:leading_columns` opts (`collation: "C"`, which
  `Ecto.Migration.add/3` already accepts).

Like `:leading_columns`, both apply to a fresh create only.

## Replace a hand-written migration at the same version

To replace a hand-written migration with the helper **at the same migration
version**, so that a database that already ran it runs nothing again:

1. Configure the options above until the helper's tables match yours. Prove
   it on a scratch database: build one copy with your migration and one with
   the helper under a different `:table_prefix`, then compare
   `information_schema.columns` (name, type, collation, nullability, ordinal
   position) and `pg_indexes` table for table, with the prefix stripped. The
   diff must be empty. This package's own suite makes exactly that comparison
   against a hand-written mirror.
2. Replace the body of your migration with the helper calls covering the
   versions it stood in for, capped with `from:` and `version:` as [How to
   set up the Ecto adapter](ecto-adapter.md) describes - a migration that
   stood in for V01 through V05 becomes `up(for: MyApp.Persistence, version:
   5)` with `down(for: MyApp.Persistence, from: 5)`. Keep the file's name and
   version number.

`Ecto.Migrator` records that version as already run on every existing
database, so the new body only ever runs on a fresh one, where it builds what
the comparison proved identical.
