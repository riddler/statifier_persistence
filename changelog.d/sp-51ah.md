### Changed

- `StatifierPersistence.Execution.from_record/1` no longer returns `donedata: nil` for every record: it reads a recorded `{:done, donedata}` answer back as `donedata`, so a fetched completed child of a durable subchart, a fan-out child's included, carries the donedata it answered its parent with. A host that matches `donedata: nil` on such a record sees the donedata instead.
- A durable subchart's single child records its answer on its own execution record before its parent's door is tried, so an answer a parked or unreachable parent refused can be delivered again through `StatifierPersistence.Driver.answer_parent/3` from the child's fetched record; a single child that ended before this release has no recorded answer and still reads `donedata: nil`.
