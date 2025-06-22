defmodule FalEx.Auth do
  @moduledoc """
  Authentication module for FalEx client.

  Handles API key authentication and temporary token generation
  for browser/realtime clients.
  """

  alias FalEx.Config

  @token_expiration_seconds 120

  @doc """
  Generates authentication headers based on the provided credentials.

  ## Examples

      iex> FalEx.Auth.to_headers("key_123456")
      [{"Authorization", "Key key_123456"}]
      
      iex> FalEx.Auth.to_headers({"id_123", "secret_456"})
      [{"Authorization", "Key id_123:secret_456"}]
  """
  def to_headers(nil), do: []

  def to_headers(api_key) when is_binary(api_key) do
    [{"Authorization", "Key #{api_key}"}]
  end

  def to_headers({key_id, key_secret}) when is_binary(key_id) and is_binary(key_secret) do
    [{"Authorization", "Key #{key_id}:#{key_secret}"}]
  end

  @doc """
  Generates a temporary authentication token for browser/realtime usage.

  This is used when connecting to streaming or WebSocket endpoints from
  environments where exposing the main API key would be insecure.

  ## Options

    * `:allowed_apps` - List of allowed app IDs (default: ["*"])
    * `:token_expiration` - Token expiration time in seconds (default: 120)

  ## Examples

      iex> {:ok, token} = FalEx.Auth.create_temporary_token(config)
      iex> is_binary(token)
      true
  """
  def create_temporary_token(%Config{} = config, opts \\ []) do
    credentials = Config.resolve_credentials(config)

    if credentials == nil do
      {:error, "No credentials configured"}
    else
      headers = to_headers(credentials)

      body = %{
        "allowed_apps" => Keyword.get(opts, :allowed_apps, ["*"]),
        "token_expiration" => Keyword.get(opts, :token_expiration, @token_expiration_seconds)
      }

      case make_token_request(config, headers, body) do
        {:ok, %{"token" => token}} ->
          {:ok, token}

        {:ok, response} ->
          {:error, "Unexpected response: #{inspect(response)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Checks if credentials are present in the configuration.
  """
  def has_credentials?(%Config{} = config) do
    Config.resolve_credentials(config) != nil
  end

  @doc """
  Gets the base authentication headers for a request.

  Includes credentials if present and not using a proxy.
  """
  def get_request_headers(%Config{} = config) do
    if Config.using_proxy?(config) do
      []
    else
      credentials = Config.resolve_credentials(config)
      to_headers(credentials)
    end
  end

  # Private functions

  defp make_token_request(config, headers, body) do
    # Build Tesla client with JSON encoding
    middleware = [
      {Tesla.Middleware.BaseUrl, Config.get_base_url(config)},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers, headers}
    ]

    client = Tesla.client(middleware)

    case Tesla.post(client, "/auth/token", body) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, "Token request failed with status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Token request failed: #{inspect(reason)}"}
    end
  end
end
