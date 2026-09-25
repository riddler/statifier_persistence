defmodule StatifierPersistence.Storage.EctoScopedConformanceTest do
  # The whole suite again, against a host that places a leading column in
  # a Postgres schema of its own, with `prune_scope:` given: the scoped
  # prune case is generated here and nowhere else.
  use StatifierPersistence.Testing.StorageConformance,
    async: true,
    adapter: StatifierPersistence.Storage.Ecto,
    opts: [persistence: StatifierPersistence.EctoHosts.Scoped, sandbox: true],
    prune_scope: [
      inside: [tenant_id: "tenant-a"],
      outside: [tenant_id: "tenant-b"],
      place: {StatifierPersistence.Test.ScopePlacement, :place}
    ]
end
