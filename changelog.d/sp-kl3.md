### Fixed

- A fan-out invocation whose children settle concurrently no longer answers with
  a `nil` donedata for a child that completed: a settlement waits for every
  child's answer to be recorded, not only for every child's status to be
  terminal, and records its own answer under the parent's exclusion.
