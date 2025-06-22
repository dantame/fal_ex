defmodule FalEx.Config do
  @moduledoc """
  Configuration module for FalEx client.

  Handles authentication credentials and client configuration.
  Supports environment variables and runtime configuration.
  """

  defstruct [
    :credentials,
    :proxy_url,
    :request_middleware,
    :response_handler,
    fetch_implementation: nil,
    base_url: "https://fal.run"
  ]

  @type credentials ::
          String.t() | {String.t(), String.t()} | (-> String.t() | {String.t(), String.t()})

  @type t :: %__MODULE__{
          credentials: credentials() | nil,
          proxy_url: String.t() | nil,
          request_middleware: module() | nil,
          response_handler: (Tesla.Env.t() -> any()) | nil,
          fetch_implementation: module() | nil,
          base_url: String.t()
        }

  @doc """
  Creates a new configuration.

  ## Options

    * `:credentials` - API credentials. Can be:
      - A string API key
      - A tuple of `{key_id, key_secret}`
      - A function that returns either of the above
    * `:proxy_url` - URL of a proxy server to route requests through
    * `:request_middleware` - Custom middleware module for request modification
    * `:response_handler` - Custom response handler function
    * `:fetch_implementation` - Custom HTTP client implementation
    * `:base_url` - Base URL for API requests (default: "https://fal.run")

  ## Examples

      # Using API key from environment
      FalEx.Config.new(credentials: System.get_env("FAL_KEY"))
      
      # Using key ID and secret
      FalEx.Config.new(credentials: {"key_id", "key_secret"})
      
      # Using a resolver function
      FalEx.Config.new(credentials: fn -> System.get_env("FAL_KEY") end)
      
      # Using proxy
      FalEx.Config.new(proxy_url: "/api/fal/proxy")
  """
  def new(opts \\ []) do
    # Merge with application config, with explicit opts taking precedence
    app_config = Application.get_all_env(:fal_ex)
    merged_opts = Keyword.merge(app_config, opts)

    config = struct(__MODULE__, merged_opts)

    # Resolve credentials from environment if not provided
    config
    |> maybe_resolve_env_credentials()
    |> validate_browser_credentials()
  end

  @doc """
  Resolves credentials at runtime.

  Handles credential resolver functions and returns the actual credentials.
  """
  def resolve_credentials(%__MODULE__{credentials: nil}), do: nil

  def resolve_credentials(%__MODULE__{credentials: fun}) when is_function(fun, 0) do
    fun.()
  end

  def resolve_credentials(%__MODULE__{credentials: creds}), do: creds

  @doc """
  Checks if the configuration uses a proxy.
  """
  def using_proxy?(%__MODULE__{proxy_url: nil}), do: false
  def using_proxy?(%__MODULE__{proxy_url: _}), do: true

  @doc """
  Gets the effective base URL, considering proxy configuration.
  """
  def get_base_url(%__MODULE__{proxy_url: nil, base_url: base_url}), do: base_url
  def get_base_url(%__MODULE__{proxy_url: proxy_url}), do: proxy_url

  # Private functions

  defp maybe_resolve_env_credentials(%__MODULE__{credentials: nil} = config) do
    creds = resolve_env_credentials()
    %{config | credentials: creds}
  end

  defp maybe_resolve_env_credentials(config), do: config

  defp resolve_env_credentials do
    # Check in order of precedence: env vars -> app config
    get_env_key() || get_env_key_pair() || get_app_config_key() || get_app_config_key_pair()
  end

  defp get_env_key do
    System.get_env("FAL_KEY")
  end

  defp get_env_key_pair do
    case {System.get_env("FAL_KEY_ID"), System.get_env("FAL_KEY_SECRET")} do
      {id, secret} when not is_nil(id) and not is_nil(secret) -> {id, secret}
      _ -> nil
    end
  end

  defp get_app_config_key do
    Application.get_env(:fal_ex, :api_key)
  end

  defp get_app_config_key_pair do
    case {Application.get_env(:fal_ex, :api_key_id),
          Application.get_env(:fal_ex, :api_key_secret)} do
      {id, secret} when not is_nil(id) and not is_nil(secret) -> {id, secret}
      _ -> nil
    end
  end

  defp validate_browser_credentials(config) do
    if running_in_browser?() and not using_proxy?(config) and resolve_credentials(config) != nil do
      IO.warn("""
      You are using fal_ex in the browser without a proxy.
      This is not recommended as it exposes your credentials.

      Consider using a proxy server to protect your API keys.
      See: https://github.com/yourusername/fal_ex#proxy
      """)
    end

    config
  end

  defp running_in_browser? do
    # In Elixir, we're always server-side, but this is here for compatibility
    # and potential future LiveView/client-side usage
    false
  end
end
