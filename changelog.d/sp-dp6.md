### Fixed

- Custom key-generator validation in `use StatifierPersistence.Ecto` no longer
  fails spuriously when the generator module is still being compiled by the
  host's parallel compiler; validation now waits for in-flight compilation
  (`Code.ensure_compiled/1`) instead of checking `Code.ensure_loaded?/1`.
