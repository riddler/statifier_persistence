### Changed

- V06's `down/1` is a no-op, so a rollback never renames the durable table
  back to its pre-0.12.0 name. V01-V05 drop the tables under the execution
  names on every install this package can reach at 0.12.0, and returning to
  the retired names would only be meaningful under a downgrade to
  pre-0.12.0 code, which is unsupported - restore from a backup instead.
  This is what makes `mix ecto.rollback --all` work for a host that writes
  one migration per package version: a conditional rename would run in its
  own rollback step and the steps behind it would then name objects that
  are no longer there.
