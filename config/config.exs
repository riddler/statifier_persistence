import Config

# This package carries no runtime app-env configuration of its own (ADR-0002
# decision 3: Ecto configuration is compile-time, on the host's module, never
# app env). The only thing config/ configures is the test harness's own repo,
# so only :test has an env-specific file to import.
if config_env() == :test do
  import_config "test.exs"
end
