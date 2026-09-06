### Added

- A chart can now fail its own run: settling in a top-level `<final>` whose
  `<donedata>` carries `statifier_persistence:run_status` set to `"failed"`
  persists the run as `:failed` with the `failure` string `"failed_final"`,
  so a `:first_error` fan-out cancels the failed child's siblings with no
  host-side translation.
