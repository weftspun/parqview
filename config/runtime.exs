import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/parqview start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :parqview, ParqviewWeb.Endpoint, server: true
end

config :parqview, ParqviewWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :parqview, ParqviewWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/parqview_web/router\.ex$"E,
        ~r"lib/parqview_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  # This ships as a self-contained desktop viewer, not a shared server: there is
  # no operator to set a secret, so generate one per boot. The cost is that
  # LiveView sessions do not survive a restart, which for a local browser is
  # invisible. Set SECRET_KEY_BASE explicitly if you ever expose it beyond
  # localhost.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      (:crypto.strong_rand_bytes(48) |> Base.encode64() |> binary_part(0, 64))

  host = System.get_env("PHX_HOST") || "localhost"

  config :parqview, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :parqview, ParqviewWeb.Endpoint,
    # this release IS the server; there is no separate `mix phx.server` step
    server: true,
    # A local viewer is served over plain http on its own port. Advertising
    # https/443 here would make the LiveView JS dial wss://host:443, which never
    # connects — the page renders but every click is inert.
    url: [host: host, port: String.to_integer(System.get_env("PORT") || "4000"), scheme: "http"],
    check_origin: false,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :parqview, ParqviewWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :parqview, ParqviewWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# Burrito binaries are handed a directory to browse and a port to listen on.
if System.get_env("RELEASE_NAME") do
  config :parqview, dir: System.get_env("PARQVIEW_DIR") || File.cwd!()
end
