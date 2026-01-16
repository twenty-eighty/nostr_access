defmodule NostrAccess.MixProject do
  use Mix.Project

  def project do
    [
      app: :nostr_access,
      version: "0.3.1",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir library for querying Nostr relays with caching and deduplication",
      package: package(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true,
        plt_add_apps: [:mix, :ex_unit]
      ],
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {NostrAccess.Application, []}
    ]
  end

  defp deps do
    [
      {:websockex, "~> 0.4"},
      {:cachex, "~> 4.0"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:stream_data, "~> 0.6", only: :test}
    ]
  end

  defp package do
    [
      maintainers: ["Twenty Eighty"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/twenty-eighty/nostr_access"},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      source_url: "https://github.com/twenty-eighty/nostr_access"
    ]
  end

  defp escript do
    [
      main_module: NostrAccess.CLI,
      name: "nostr_access"
    ]
  end
end
