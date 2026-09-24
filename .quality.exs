# Quality configuration for statifier_persistence.
#
#   mix quality                 - full gate: format, compile, credo, dialyzer,
#                                 deps audit, docs, doc links, full test
#                                 suite with coverage. Run before every
#                                 commit.
#
#   mix quality --profile loop  - inner loop while implementing: skips dialyzer
#                                 and coverage, runs only the tests covering
#                                 changed code. Use between edits.
#
# Agents: prefer `--format json --report -` when you want to route on results.
#
# Deliberately smaller than statifier-ex's gate. That repo's custom stages -
# the gate guard, the ADR guard and judge, the regression ratchet - all exist
# to protect a conformance corpus and an accepted ADR set this package does
# not have. Adopting any of them here is a decision to record when there is
# something for it to protect, not a default to inherit.
#
# There is deliberately no .credo.exs either: credo's own defaults under
# --strict are the gate until this package has a reason to deviate from one.

[
  compile: [
    warnings_as_errors: true
  ],

  # Check-mode, not reformat-mode (sui-b5y, fleet-wide decision 2026-08-22):
  # a gate that rewrites drifting files cannot report drift as a finding, so
  # unformatted code would pass instead of going red. Drift fails the stage;
  # run `mix format` yourself before committing.
  format: [
    check: true
  ],

  credo: [
    strict: true
  ],

  # The two docs stages make `mix quality` the pre-publish check for this
  # package's HexDocs, locally and in CI. The Docs stage runs `mix docs` and
  # fails on any ExDoc warning. The doc_links stage fails on the link rules
  # ExDoc accepts silently: a README relative link to a file not in the
  # package files, a published relative link to a file that is not an extra,
  # two extras sharing a basename, and a silent rewrite to a different extra.
  docs: [
    enabled: :auto
  ],
  doc_links: [
    enabled: :auto
  ],
  profiles: [
    loop: [
      stages: [:format, :compile, :credo, :test],
      test: [scope: :changed, coverage: false]
    ]
  ]
]
