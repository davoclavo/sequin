import Config

# Note we also include the path to a cache manifest
# containing the digested version of static files. This
# manifest is generated by the `mix assets.deploy` task,
# which you should run after static files are built and
# before starting your production server.

self_hosted = System.get_env("SELF_HOSTED", "0") in ~w(1 true)

config :sentry,
  dsn: System.get_env("SENTRY_DSN"),
  release: System.get_env("RELEASE_VERSION")

config :sequin, Sequin.ConsoleLogger, drop_metadata_keys: [:mfa]

config :sequin,
  self_hosted: self_hosted,
  portal_hostname: "portal.sequin.local",
  release_version: System.get_env("RELEASE_VERSION")

# Configures Swoosh API Client
config :swoosh, Sequin.Mailer, adapter: Swoosh.Adapters.Sendgrid

# Disable Swoosh Local Memory Storage
config :swoosh, local: false, api_client: Swoosh.ApiClient.Req

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
