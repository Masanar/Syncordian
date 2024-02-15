defmodule BizantineLogoot.MixProject do
  @moduledoc """
  """
  use Mix.Project

  def project do
    [
      app: :bizantine_logoot,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:type_check, "~> 0.13.3"},
      # To allow spectesting and property-testing data generators (optional):
      {:stream_data, "~> 0.5.0", only: :test},
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      {:ex_doc, "~> 0.21", only: :dev, runtime: false}
    ]
  end
end
