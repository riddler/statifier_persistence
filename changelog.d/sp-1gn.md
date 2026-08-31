### Added

- `StatifierPersistence.Driver` drives a durable run to quiescence over
  `StatifierPersistence.Runs`: it performs each `<invoke>` through a
  host-supplied dispatch fun inside the step that emitted it, then steps
  every answer back in until the chart rests. Hosts that hand-rolled this
  loop can delete it.
- `StatifierPersistence.Driver` builds an invocation's answer events -
  `done.invoke.<id>` and `error.communication.invoke.<id>`, `origin` and
  `origintype` included - field for field from `Statifier.Session`'s own
  `done_invocation/3` and `failed_invocation/3`, so a chart sees the same
  event in a session and out of storage. A conformance test answers one
  document both ways and compares what each chart saw.
