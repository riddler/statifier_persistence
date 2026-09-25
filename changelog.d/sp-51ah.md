### Changed

- A durable subchart's single child now records its answer on its own execution record before its parent's door is tried, and `StatifierPersistence.Execution.from_record/1` reads a recorded `{:done, donedata}` back as `donedata`, so an answer a parked or unreachable parent refused can be delivered again through `StatifierPersistence.Driver.answer_parent/3` from the child's fetched record; a child that ended before this release has no recorded answer and still reads `donedata: nil`.
