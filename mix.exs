defmodule FalEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/yourusername/fal_ex"

  def project do
    [
      app: :fal_ex,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {FalEx.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # HTTP client with middleware support
      {:tesla, "~> 1.8"},
      {:hackney, "~> 1.20"},

      # JSON encoding/decoding
      {:jason, "~> 1.4"},

      # MessagePack support
      {:msgpax, "~> 2.3"},

      # WebSocket client
      {:websockex, "~> 0.4.3"},

      # For streaming and flow control
      {:gen_stage, "~> 1.2"},

      # SSE client
      {:mint, "~> 1.5"},
      {:castore, "~> 1.0"},

      # File type detection
      {:infer, "~> 0.2.4"},

      # Development dependencies
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:bypass, "~> 2.1", only: :test},
      {:stream_data, "~> 0.6", only: [:dev, :test]}
    ]
  end

  defp description do
    "Elixir client library for fal.ai - Serverless AI/ML model inference"
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "fal.ai" => "https://fal.ai"
      },
      maintainers: ["Your Name"]
    ]
  end

  defp docs do
    [
      main: "FalEx",
      extras: ["README.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end
