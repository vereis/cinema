defmodule Cinema.MixProject do
  use Mix.Project

  def project do
    [
      app: :cinema,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      dialyzer: [
        plt_add_apps: [:iex, :mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        flags: [:error_handling]
      ],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        lint: :test,
        dialyzer: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "test.watch": :test
      ],
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp has_oban_pro? do
    Hex.start()
    match?(%{url: "https://getoban.pro/repo"}, Hex.State.fetch!(:repos)["oban"])
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto, "~> 3.6"},
      {:ecto_sql, "~> 3.11"},
      {:jason, "~> 1.2"},
      {:postgrex, "~> 0.15"},
      {:sibyl, "~> 0.1.9"},
      {:libgraph, "~> 0.16.0"},

      # Runtime dependencies for tests / linting
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.28", only: :dev},
      {:ex_machina, "~> 2.7", only: :test},
      {:excoveralls, "~> 0.10", only: :test},
      {:mix_test_watch, "~> 1.0", only: [:test], runtime: false},
      {:styler, "~> 0.11", only: [:dev, :test], runtime: false}
      | (has_oban_pro?() && [{:oban, "~> 2.18"}, {:oban_pro, "~> 1.5.0-rc.1", repo: "oban"}]) ||
          []
    ]
  end

  defp aliases do
    [
      test: ["coveralls.html --trace --slowest 10"],
      lint: [
        "format --check-formatted --dry-run",
        "credo --strict",
        "compile --warnings-as-errors",
        "dialyzer"
      ]
    ]
  end
end
