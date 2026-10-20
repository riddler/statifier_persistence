# Documents, revisions, charts and executions, and why an execution is a durable row

This package has no table for a document and no table for a revision. Both
belong to your host. What the package stores, of these four words, is the
chart and the execution. This page explains how the four line up, why the
split falls where it does, and why an execution is a row that outlives every
process rather than a process that happens to be saved.

Nothing else in these pages says how a host gets from "the workflow an author
edits" to "the chart an execution runs", so the four words are written down
here once.

## Four words, one job each

Each word has exactly one job:

- A **document** is the stable thing a host names - the workflow an author
  opens and edits - under an id the host owns. A lending desk's "lend a copy
  of a book" workflow is a document.
- A **revision** is one saved state of a document. In these pages the word
  always means that, and nothing the package stores is called a revision.
- A **chart** is what a revision compiles to, identified by its content
  hash. Documents and revisions never reach this package.
- An **execution** runs exactly one chart for its whole life. One patron's
  loan of one copy is an execution.

The sentence "the chart and the execution are what the package stores" holds
inside these four words only; it is not a list of everything the Ecto adapter
creates. The upstream statifier records, quoted below, say "chart revision"
for what this page calls a chart: the compiled form, which is not a document's
revision.

## Why documents and revisions stay with the host

An author edits a document, and every save is a revision. Those are
authoring facts, and they change at the author's pace. A chart is what the
engine can run: it is identified by its content hash, so the package never
needs to know which document or which revision produced it. It receives a
compiled chart and files it under the hash of its content.

That is why nothing that starts an execution names a document or a revision
to this package. The only thing that crosses from the host's side to the
package's side is a hash, and the host is the one that knows which hash is
current.

## The publish row

The join between the two sides is a publish row the **host** keeps:

    (document_id, revision, content_hash, published_at, status)

Three rules govern it:

- There is exactly one active publish per document.
- A new execution always starts on the document's active publish, and
  nothing that starts an execution names a content hash directly: the host
  reads the hash off the active publish.
- A republish mints a new chart and never touches a live execution. An
  execution drains on the chart it started on.

A lending desk starts each new loan through its own publish row rather than
through a hash it carries around. The snippet below illustrates that read; it
is not a procedure. `store`, `machine` and `opts` are the values [How to
persist an execution and resume it in another
process](../guides/persist-and-resume.md) builds (its "Store the compiled
chart" and "Connect your host to the effects" steps), and `MyApp.Catalog` is
the host's publish table, not this package's:

```elixir
%{content_hash: hash} = MyApp.Catalog.active_publish!("lend-a-copy")

{:ok, %{chart_blob: blob}} = Storage.fetch_chart(store, hash)
{:ok, machine} = Chart.from_binary(blob)
{:ok, execution, _state} = Executions.create(store, "loan_01H8", machine, opts)
```

## Why an execution is a durable row

A loan can stay open for days: a copy is out with a patron, comes due, is
renewed, and is returned. No process should have to stay alive for that long.
So between two steps nothing holds the execution in memory. The only thing
that exists is the execution's record, and it is enough: given only the
execution id, you fetch the record, fetch the chart bytes it names, and
recompile.

Two facts make that safe, and both follow from the execution running exactly
one chart for its whole life:

- A position is only meaningful against the exact chart that produced it.
  The record therefore names its chart by content hash, and the identity
  guard checks that hash on every load.
- A republish mints a new chart and never touches a live execution. The
  execution keeps resuming on the chart it started on, so an author saving a
  new revision cannot change what a loan already in progress will do. It
  drains on its own chart.

If the execution were a process, a restart would end it and a republish would
have to decide what to do with it. Because it is a row naming one chart, a
restart changes nothing about how it continues, and a republish has nothing
to decide. [Surviving a restart: the demo host](../restart-demo.md) walks a demo host
through that.

## The contract this package builds on

The persisted-position story is already specified upstream, in statifier-ex,
and this package is one consumer of it rather than the definition of it:

- `docs/persistence.md` in statifier-ex covers what MachineState contains, the
  interned-index hazard, chart identity, and the resume recipe.
- ADR-0052 there records the rules: a persisted position is only meaningful
  against the exact chart that produced it (the upstream record says "chart
  revision"; it means the compiled chart, as above), so every load is guarded
  by the Machine identity / content-hash. Loading a position against the wrong
  chart does not error - it silently resumes the wrong configuration.
- ADR-0060 records the resume API: the `:resume` option on
  `Session.start_link/2`, the pure-core rehydration path, and what a resume
  deliberately does not restore (in-flight delayed-send timers and live
  invoked children).

Read all three before adding code here.
