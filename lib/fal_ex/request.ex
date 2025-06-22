defmodule FalEx.Request do
  @moduledoc """
  HTTP request handling for FalEx client.

  Builds URLs, dispatches requests, and handles responses using Tesla.
  """

  alias FalEx.{Auth, Response}

  require Logger

  @doc """
  Builds a URL for the given endpoint ID and options.

  ## Examples

      iex> FalEx.Request.build_url("fal-ai/fast-sdxl", %{})
      "https://fal.run/fal-ai/fast-sdxl"

      iex> FalEx.Request.build_url("12345", %{subdomain: "queue"})
      "https://queue.fal.run/12345"
  """
  def build_url(endpoint_id, opts \\ %{}) do
    base = opts[:base_url] || "https://fal.run"
    subdomain = opts[:subdomain]
    path = opts[:path] || ""

    url =
      if subdomain do
        # For localhost testing, append subdomain as path prefix instead
        if String.contains?(base, "localhost") do
          base
        else
          base
          |> String.replace("://", "://#{subdomain}.")
        end
      else
        base
      end

    # For localhost with subdomain, prepend subdomain to path
    final_path =
      if subdomain && String.contains?(base, "localhost") do
        "/#{subdomain}/#{endpoint_id}#{path}"
      else
        "/#{endpoint_id}#{path}"
      end

    "#{url}#{final_path}"
  end

  @doc """
  Dispatches an HTTP request.

  ## Options

    * `:method` - HTTP method (default: :post)
    * `:input` - Request payload
    * `:config` - FalEx configuration
    * `:options` - Additional request options (headers, timeout, etc.)
  """
  def dispatch_request(opts) do
    method = opts[:method] || :post
    url = opts[:target_url]
    input = opts[:input]
    config = opts[:config]
    request_options = opts[:options] || %{}

    if url == nil do
      {:error, :invalid_request}
    else
      # Build middleware stack
      middleware = build_middleware(config, request_options)

      # Create Tesla client
      client = Tesla.client(middleware)

      # Prepare request body
      body = prepare_body(input)

      # Make request and handle response
      method
      |> execute_request(client, url, body)
      |> handle_request_result(config)
    end
  end

  defp prepare_body(nil), do: nil
  defp prepare_body(%{} = input) when map_size(input) == 0, do: %{}
  defp prepare_body(input), do: input

  defp execute_request(:get, client, url, _body), do: Tesla.get(client, url)
  defp execute_request(:post, client, url, body), do: Tesla.post(client, url, body)
  defp execute_request(:put, client, url, body), do: Tesla.put(client, url, body)
  defp execute_request(:delete, client, url, _body), do: Tesla.delete(client, url)

  defp execute_request(method, _client, _url, _body),
    do: {:error, "Unsupported method: #{method}"}

  defp handle_request_result({:ok, %Tesla.Env{} = env}, config) do
    handle_response(env, config)
  end

  defp handle_request_result({:error, reason}, _config) do
    {:error, reason}
  end

  @doc """
  Parses an endpoint ID into its components.

  ## Examples

      iex> FalEx.Request.parse_endpoint_id("fal-ai/fast-sdxl")
      %{owner: "fal-ai", alias: "fast-sdxl"}

      iex> FalEx.Request.parse_endpoint_id("12345")
      %{path: "12345"}
  """
  def parse_endpoint_id(endpoint_id) do
    if String.contains?(endpoint_id, "/") do
      [owner, alias] = String.split(endpoint_id, "/", parts: 2)
      %{owner: owner, alias: alias}
    else
      %{path: endpoint_id}
    end
  end

  # Private functions

  defp build_middleware(config, request_options) do
    timeout_value =
      case Map.get(request_options, :timeout) do
        nil -> 300_000
        timeout -> timeout
      end

    base_middleware = [
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers, build_headers(config, request_options)},
      {Tesla.Middleware.Timeout, timeout: timeout_value}
    ]

    # Add custom middleware if configured
    if config.request_middleware do
      [config.request_middleware | base_middleware]
    else
      base_middleware
    end
  end

  defp build_headers(config, request_options) do
    # Start with base headers
    headers = [
      {"Accept", "application/json"},
      {"Content-Type", "application/json"},
      {"User-Agent", "fal-ex/#{version()}"}
    ]

    # Add auth headers
    auth_headers =
      Auth.get_request_headers(config)

    headers = headers ++ auth_headers

    # Add custom headers
    custom_headers = Map.get(request_options, :headers, [])
    headers ++ custom_headers
  end

  defp handle_response(%Tesla.Env{status: status, body: body} = env, config) do
    # Use custom response handler if configured
    if config.response_handler do
      config.response_handler.(env)
    else
      # Default response handling
      handle_status_code(status, body)
    end
  end

  defp handle_status_code(status, body) when status in 200..299 do
    {:ok, body}
  end

  defp handle_status_code(status, body) when status in [400, 422] do
    {:error, Response.validation_error(body)}
  end

  defp handle_status_code(401, body) do
    {:error, Response.api_error("Unauthorized", 401, body)}
  end

  defp handle_status_code(403, body) do
    {:error, Response.api_error("Forbidden", 403, body)}
  end

  defp handle_status_code(404, body) do
    {:error, Response.api_error("Not found", 404, body)}
  end

  defp handle_status_code(429, body) do
    {:error, Response.api_error("Rate limited", 429, body)}
  end

  defp handle_status_code(status, body) when status >= 500 do
    {:error, Response.api_error("Server error", status, body)}
  end

  defp handle_status_code(status, body) do
    {:error, Response.api_error("Request failed", status, body)}
  end

  defp version do
    Application.spec(:fal_ex, :vsn) |> to_string()
  end
end
