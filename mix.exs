defmodule Syncordian.MixProject do
  use Mix.Project

  def project do
    [
      app: :syncordian,
      version: "0.1.0",
      elixir: "~> 1.18.3",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      name: "Syncordian",
      source_url: "https://github.com/Masanar/Syncordian",
      docs: docs()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Syncordian.Application, []},
      extra_applications: [:logger, :runtime_tools, :observer, :wx]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # {:type_check, "~> 0.13.3"},
      {:phoenix, "~> 1.7.12"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 0.20.2"},
      {:floki, ">= 0.30.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.5"},
      {:finch, "~> 0.13"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.20"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.2"},
      {:phoenix_live_session, "~> 0.1"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # ExDoc configuration. Run `mix docs` to generate a self-contained, browsable
  # HTML documentation site under `doc/` (open `doc/index.html`). Modules are
  # grouped by sub-system so the four CRDT implementations stay visually
  # separated from the shared infrastructure and the Phoenix web layer.
  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      groups_for_modules: [
        "Syncordian CRDT": [
          Syncordian.Peer,
          Syncordian.Document,
          Syncordian.Line,
          Syncordian.Line_Object,
          Syncordian.PathId,
          Syncordian.Byzantine,
          Syncordian.ByzantinePeer,
          Syncordian.Interleaving,
          Syncordian.PendingOps,
          Syncordian.SeenOps,
          Syncordian.Info
        ],
        "Fugue CRDT": [
          Syncordian.CRDT.Fugue.Peer,
          Syncordian.CRDT.Fugue.Tree,
          Syncordian.CRDT.Fugue.Node,
          Syncordian.CRDT.Fugue.Info
        ],
        "Logoot CRDT": [
          Syncordian.CRDT.Logoot.Peer,
          Syncordian.CRDT.Logoot.Sequence,
          Syncordian.CRDT.Logoot.Agent,
          Syncordian.CRDT.Logoot.Info
        ],
        "Treedoc CRDT": [
          Syncordian.CRDT.Treedoc.Peer,
          Syncordian.CRDT.Treedoc.Bst,
          Syncordian.CRDT.Treedoc.Node
        ],
        "Shared infrastructure": [
          Syncordian.Basic_Types,
          Syncordian.Utilities,
          Syncordian.Metadata,
          Syncordian.Vector_Clock
        ],
        "Experiment driver": [
          Syncordian.Supervisor,
          Syncordian.GitParser,
          Mix.Tasks.Syncordian.Eval
        ],
        "Web (Phoenix / LiveView)": [
          SyncordianWeb,
          SyncordianWeb.Endpoint,
          SyncordianWeb.Router,
          SyncordianWeb.Telemetry,
          SyncordianWeb.About,
          SyncordianWeb.Node,
          SyncordianWeb.Supervisor,
          SyncordianWeb.ReadmeLog,
          SyncordianWeb.CoreComponents,
          SyncordianWeb.Layouts
        ]
      ]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind syncordian", "esbuild syncordian"],
      "assets.deploy": [
        "tailwind syncordian --minify",
        "esbuild syncordian --minify",
        "phx.digest"
      ]
    ]
  end
end
