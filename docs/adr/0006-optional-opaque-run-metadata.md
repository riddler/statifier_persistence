# ADR-0006: Optional opaque run metadata: identities only, refusable by an adapter

Status: accepted (2026-08-29, accepted under the operator campaign-015 direction-agent gate grant, PR 27)

## Context

A run record is keyed by its `run_id` and carries engine identities and
opaque blobs only: `status`, `content_hash`, `identity_blob`, a nullable
`position_blob`, and `failure` (ADR-0004 decision 1). The positions table,
not the run record, is the session-keyed one (ADR-0003 decision 3).
Nothing on the run record answers the question a multi-tenant host asks
first - "list the runs for scope X" - where X is a tenant, a subject
entity, or a correlation id the host already keys its own tables by.
Today such a host maintains a side table keyed by `run_id` and joins it
against the runs table itself.

The decision bead (sp-8in) framed two arms and asked that the trade be
weighed explicitly rather than assumed:

- **(a)** an optional opaque metadata map on runs - a widening of the
  adapter contract surface, reaching every implementer of
  `StatifierPersistence.Storage.Adapter`.
- **(b)** bless the side-table pattern in the persistence guidance with a
  worked example, keeping the package minimal.

Two facts decide the trade rather than taste. First, the widening in arm
(a) is optional-by-refusal, not mandatory: an adapter that stores nothing
extra stays conformant by refusing a non-empty map at open, the same
`@optional_callbacks` plus `function_exported?/3` shape ADR-0003's
`isolate/1` and `lock_run/3` amendments already established here. The
"widens the contract for every implementer" cost is therefore paid only by
implementers who want the feature. Second, arm (b) does not actually keep
the host's join off this package's tables: a side table keyed by `run_id`
is a foreign key into a schema ADR-0002 lets the host rename and prefix,
so the pattern the guidance would bless is one this package cannot keep
stable for the host anyway.

The hazard arm (a) creates is disclosure, and it is created by a decision
made elsewhere in this repository. sp-km3's `:blob_type` option, now
landed, encrypts the chart and position blobs at rest; a metadata column
is not a blob and is not covered by it. A host that files a customer's
name, email, or card data into a queryable metadata column has defeated
its own encryption at rest while believing it is on - the encryption is
still working, on the columns it covers. That is why decision 2 below is
written as a hard rule in the record rather than left as advice in a guide.

## Decision

**1. `Runs.create/4` accepts an optional `metadata` map, opaque to this
package.** The option is `metadata: %{String.t() => term}`, default absent
(equivalent to the empty map). The map is opaque here in the strong sense
ADR-0003 decision 1 uses for `chart_blob`: this package never reads a key
or a value to make a decision, never validates beyond the shape above
(string keys, a map), and never merges it into the chart or position blobs.
It is stored beside the run record and handed back on fetch, unchanged.
Nothing in the step loop, the executor seam, or the identity guard consults
it.

**2. The map carries identities only, never personal data.** This is a
hard rule of the contract, not a recommendation: keys and values are host
identities - a tenant id, a subject-entity id, a correlation id - and never
a name, an email address, a postal address, a card number, or any other
personal or cardholder data. The reason is stated in decision form because
a host cannot infer it from the API's shape: blob encryption (sp-km3's
`:blob_type`) covers the chart and position blobs and does not reach this
column, so data placed here is at rest in the clear no matter how the blobs
are configured. For a card-processing host running a `myapp:authorize` /
`myapp:capture` chart, the conforming shape is
`%{"tenant_id" => "acct_01H8X...", "processor_account_id" => "pacct_4471"}`
- the account ids it already keys its own tables by - and never the
cardholder's name or PAN.

**3. An adapter that cannot store metadata refuses at open.** The contract
arm is `{:error, :metadata_unsupported}`, returned when a non-empty map is
supplied to an adapter that does not support the column. Refusal is at
open - at the create that supplies the map - not at a later fetch, so a
host learns on its first call rather than discovering a silently dropped
scope later. An empty or absent map is never refused, which is what keeps
every adapter written before this record conformant without a line of
change. Concretely:

- `StatifierPersistence.Storage.InMemory` supports metadata: it stores the
  map with the run record and returns it verbatim.
- The shipped Ecto adapter stores it as a nullable `jsonb` column on the
  runs table and exposes an equality-match list helper: list the runs whose
  metadata matches **all** of the given key/value pairs. Equality match on
  all pairs is the whole query surface - no ranges, no partial matches, no
  containment operators, and no ordering guarantee. A host needing more
  than that is running its own query against its own column, which
  ADR-0002's configurable table names already allow. `jsonb` holds only
  JSON-representable values, so `term` in the type above is narrower here
  than in Elixir: a tuple, a pid, or a reference has no `jsonb` form. What
  that adapter does with such a value - refuse at open, or raise from the
  encoder - is a failure shape sp-6ac picks, not one this record fixes.
- Any other adapter refuses, and refusing is conformance, not a gap.

**This record amends ADR-0003 decision 1.** That decision says every
data-bearing adapter callback takes and returns "binaries plus engine
identity strings", echoed as "and nothing else" in
`StatifierPersistence.Storage.Adapter`'s moduledoc, and its `isolate/1` and
`lock_run/3` amendments left the clause standing because neither callback
carries data at all. The metadata map does: it rides as a field on
`Adapter.run_record`, through `insert_run/2`, `fetch_run/2`, and
`update_run/2`. So decision 1's blobs-plus-identities clause is amended
here to also admit that one optional map of host identities - opaque in
the same strong sense as `chart_blob`, never decoded, inspected, or
interpreted by an adapter beyond storing and returning it. Nothing else in
ADR-0003 changes: the identity guard (decision 2), the engine-identity
keying (decision 3), and the error vocabulary (decision 4) all hold
unmodified. sp-6ac carries the moduledoc wording and ADR-0003's amendment
line with the code.

**4. Migration shape, conformance case, and worked example belong to the
implementation bead.** They are named here so the record and the code
cannot drift: a nullable `jsonb` column on the runs table added by the
versioned migrations helper ADR-0002 decision 3 makes the only supported
path (no index - which pairs a host queries by, and therefore which index
it wants, is the host's call and not something this package can guess);
`StatifierPersistence.Testing.StorageConformance` gains a metadata
round-trip case and a refusal case, so an adapter's answer either way is
tested rather than assumed; and the persistence guidance gains a worked
example of the identities-only shape from decision 2. sp-6ac carries all
three.

## Consequences

- The adapter behaviour's contract surface grows, but the growth is
  optional-by-refusal: an existing adapter is conformant unchanged, and
  the conformance suite tests both answers rather than only the supporting
  one.
- A host that wants scope queries no longer needs a side table joined to a
  runs table whose name it can reconfigure. A host that does not want them
  supplies nothing and sees no change at all.
- The identities-only rule is a rule this package cannot enforce - the map
  is opaque by decision 1, so nothing here can inspect a value to reject
  it. It is enforced by the record, the guidance example, and the host's
  own review. Making it enforceable would mean reading the map, which
  contradicts decision 1; that trade is deliberately not taken.
- This record does not encrypt the metadata column and does not extend
  sp-km3's `:blob_type` to reach it. A host that needs an encrypted,
  queryable scope needs a blind index, which is a different decision in a
  different package.
- What would reopen this record: a host that needs a query richer than
  equality-on-all-pairs (decision 3's helper); metadata needing to be
  mutable after create, which decision 1 does not grant; a second data
  store whose type system has no jsonb equivalent (decision 3's Ecto
  clause); or an encrypted-and-queryable requirement, which would reopen
  the disclosure argument in Context rather than only decision 2.
