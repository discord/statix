defmodule Statix.Mixfile do
  use Mix.Project

  @version "1.5.0"
  @source_url "https://github.com/discord/statix"

  def project() do
    [
      app: :discord_statix,
      version: @version,
      elixir: "~> 1.15",
      deps: deps(),

      # Hex
      description: description(),
      package: package(),

      # Docs
      name: "Statix",
      docs: docs()
    ]
  end

  def application() do
    [extra_applications: [:logger]]
  end

  defp description() do
    "Fast and reliable Elixir client for StatsD-compatible servers."
  end

  defp package() do
    [
      maintainers: ["Discord"],
      licenses: ["ISC"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp deps() do
    [{:ex_doc, "~> 0.39.1", only: :dev, runtime: false, warn_if_outdated: true}]
  end

  defp docs() do
    [
      main: "Statix",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md"
      ]
    ]
  end
end
