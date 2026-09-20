### Changed

- `StatifierPersistence.Executions.executions_on/2` answers a real `children` count: the durable-child linkage pins naming the hash whose parent execution is `:active`, in place of the zero both bundled adapters returned for that key.
