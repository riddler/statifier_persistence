### Added

- `use StatifierPersistence.Ecto` accepts `leading_columns: [name: {type, opts}]`: the migrations helper places those host-owned columns immediately after `id`, in the order given, in every table V01 and V05 create; it only places them, so a default or a `NOT NULL` belongs to a later migration of the host's own.
