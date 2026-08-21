defmodule StatifierPersistence.Storage.InMemoryConformanceTest do
  use StatifierPersistence.Testing.StorageConformance,
    adapter: StatifierPersistence.Storage.InMemory,
    opts: []
end
