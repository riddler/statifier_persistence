### Added

- `use StatifierPersistence.Ecto` takes `timestamps_position: :leading`,
  which places `inserted_at` and `updated_at` right after the leading
  columns in every table V01 and V05 create; the default, `:trailing`,
  keeps them last as before.
- `use StatifierPersistence.Ecto` takes `column_collations: [name:
  collation]`, which declares a package text column with that collation
  in every V01 or V05 `CREATE TABLE` that declares it - `execution_id:
  "C"`, for example.
