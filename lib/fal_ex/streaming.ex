defmodule FalEx.Streaming do
  @moduledoc """
  Streaming client for handling Server-Sent Events (SSE) from fal.ai.

  Provides real-time streaming of model outputs with support for partial results.
  """

  alias FalEx.{Auth, Config, Request, Storage}
  alias FalEx.Streaming.SSEHandler

  defstruct [:config]

  @type t :: %__MODULE__{
          config: Config.t()
        }

  # 15 seconds
  @default_timeout 15_000

  @doc """
  Creates a new streaming client.
  """
  def create(%Config{} = config) do
    %__MODULE__{config: config}
  end

  @doc """
  Starts a streaming request to a fal endpoint.

  Returns a stream handle that can be used to receive data chunks.

  ## Options

    * `:input` - Input payload for the model
    * `:method` - HTTP method (default: :post)
    * `:timeout` - Stream timeout in ms (default: 15000)
  """
  def stream(%__MODULE__{} = streaming, endpoint_id, opts \\ []) do
    # Transform input
    input =
      case Keyword.get(opts, :input) do
        nil -> nil
        input -> Storage.transform_input(Storage.create(streaming.config), input)
      end

    # Determine connection mode
    connection_mode = get_connection_mode(streaming.config)

    opts_map = Enum.into(opts, %{})

    case connection_mode do
      :server ->
        server_stream(streaming, endpoint_id, input, opts_map)

      :client ->
        client_stream(streaming, endpoint_id, input, opts_map)
    end
  end

  @doc """
  Gets the next chunk from a stream.

  Returns:
    * `{:ok, data, stream}` - Data chunk received
    * `{:done, stream}` - Stream completed
    * `{:error, reason}` - Error occurred
  """
  def next(stream_handle) when is_pid(stream_handle) do
    if Process.alive?(stream_handle) do
      GenServer.call(stream_handle, :next, :infinity)
    else
      {:error, :closed}
    end
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc """
  Closes a stream.
  """
  def close(stream_handle) when is_pid(stream_handle) do
    if Process.alive?(stream_handle) do
      GenServer.stop(stream_handle, :normal, 5000)
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  # Private functions

  defp get_connection_mode(config) do
    cond do
      # If using proxy, always use server mode
      Config.using_proxy?(config) -> :server
      # If credentials present, use server mode
      Auth.has_credentials?(config) -> :server
      # Otherwise client mode (would need temp token)
      true -> :client
    end
  end

  defp server_stream(streaming, endpoint_id, input, opts) do
    # Build streaming URL
    base_url = Config.get_base_url(streaming.config)

    # For localhost/testing, use /v1/stream prefix; for production, append /stream to endpoint
    url =
      if String.contains?(base_url, "localhost") do
        "#{base_url}/v1/stream/#{endpoint_id}"
      else
        # For production fal.ai, append /stream to the endpoint path
        "#{base_url}/#{endpoint_id}/stream"
      end

    # Start SSE handler process
    case SSEHandler.start_link(%{
           url: url,
           config: streaming.config,
           input: input,
           method: Map.get(opts, :method, :post),
           timeout: Map.get(opts, :timeout, @default_timeout)
         }) do
      {:ok, pid} ->
        # Wait for connection to be established
        case GenServer.call(pid, :wait_connected, 5000) do
          :ok ->
            {:ok, pid}

          {:error, reason} ->
            GenServer.stop(pid)
            {:error, reason}
        end

      error ->
        error
    end
  end

  defp client_stream(streaming, endpoint_id, input, opts) do
    # Get temporary token for client streaming
    case Auth.create_temporary_token(streaming.config) do
      {:ok, token} ->
        # Build client streaming URL
        url =
          Request.build_url(endpoint_id, %{
            subdomain: "stream",
            path: "/stream",
            base_url: Config.get_base_url(streaming.config)
          })

        # Start SSE handler with token auth
        config_with_token = %{streaming.config | credentials: token}

        {:ok, pid} =
          SSEHandler.start_link(%{
            url: url,
            config: config_with_token,
            input: input,
            method: Map.get(opts, :method, :post),
            timeout: Map.get(opts, :timeout, @default_timeout)
          })

        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule FalEx.Streaming.SSEHandler do
  @moduledoc false

  use GenServer

  require Logger

  defmodule State do
    @moduledoc false
    defstruct [
      :conn,
      :ref,
      :buffer,
      :done,
      :error,
      :pending_chunks,
      :config,
      :waiting_connected,
      :received_valid_data
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    # Start connection in background
    send(self(), {:connect, opts})

    {:ok,
     %State{
       buffer: "",
       done: false,
       pending_chunks: :queue.new(),
       config: opts.config,
       waiting_connected: [],
       received_valid_data: false
     }}
  end

  @impl true
  def handle_call(:next, _from, %State{done: true, pending_chunks: queue} = state) do
    # Check if we have pending chunks even though stream is done
    case :queue.out(queue) do
      {{:value, {:error, _} = error}, new_queue} ->
        {:reply, error, %{state | pending_chunks: new_queue}}

      {{:value, chunk}, new_queue} ->
        {:reply, {:ok, chunk}, %{state | pending_chunks: new_queue}}

      {:empty, _} ->
        # No more chunks and stream is done
        if state.received_valid_data do
          # Received valid SSE data and completed normally
          {:reply, {:ok, :done}, state}
        else
          # Connection closed without valid data
          {:reply, {:error, :closed}, state}
        end
    end
  end

  def handle_call(:next, _from, %State{error: error} = state) when not is_nil(error) do
    {:reply, {:error, error}, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:wait_connected, from, %State{conn: nil, error: nil} = state) do
    # Connection not established yet, wait
    {:noreply, %{state | waiting_connected: [from | state.waiting_connected]}}
  end

  def handle_call(:wait_connected, _from, %State{conn: conn} = state) when not is_nil(conn) do
    # Connection established
    {:reply, :ok, state}
  end

  def handle_call(:wait_connected, _from, %State{error: error} = state) when not is_nil(error) do
    # Connection failed
    {:reply, {:error, error}, state}
  end

  def handle_call(:next, from, %State{pending_chunks: queue} = state) do
    case :queue.out(queue) do
      {{:value, {:error, _} = error}, new_queue} ->
        # Return error chunks as-is
        {:reply, error, %{state | pending_chunks: new_queue}}

      {{:value, chunk}, new_queue} ->
        {:reply, {:ok, chunk}, %{state | pending_chunks: new_queue}}

      {:empty, _} ->
        # Check if connection is closed
        if state.done do
          {:reply, {:error, :closed}, state}
        else
          # Wait for more data
          Process.send_after(self(), {:check_next, from}, 50)
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:connect, opts}, state) do
    case establish_connection(opts) do
      {:ok, conn, ref} ->
        {:noreply, %{state | conn: conn, ref: ref}}

      {:error, reason} ->
        notify_waiting_clients(state.waiting_connected, {:error, reason})
        {:noreply, %{state | error: reason, waiting_connected: []}}
    end
  end

  def handle_info({:check_next, from}, state) do
    # Manually handle the deferred reply
    case handle_call(:next, from, state) do
      {:reply, reply, new_state} ->
        GenServer.reply(from, reply)
        {:noreply, new_state}

      {:noreply, new_state} ->
        {:noreply, new_state}
    end
  end

  def handle_info(message, %State{conn: conn, ref: ref} = state) do
    case Mint.HTTP.stream(conn, message) do
      :unknown ->
        {:noreply, state}

      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        handle_responses(responses, ref, state)

      {:error, _conn, reason, _responses} ->
        {:noreply, %{state | error: reason}}
    end
  end

  defp establish_connection(opts) do
    headers = build_headers(opts.config)
    body = if opts.input, do: Jason.encode!(opts.input), else: ""
    uri = URI.parse(opts.url)

    Logger.debug("Connecting to streaming URL: #{opts.url}")

    with {:ok, conn} <- connect_to_host(uri) do
      send_sse_request(conn, uri, opts.method, headers, body)
    end
  end

  defp connect_to_host(uri) do
    port = uri.port || if uri.scheme == "https", do: 443, else: 80
    scheme = scheme_to_atom(uri.scheme)

    Logger.debug("Mint connecting to #{scheme}://#{uri.host}:#{port}")
    Mint.HTTP.connect(scheme, uri.host, port)
  end

  defp send_sse_request(conn, uri, method, headers, body) do
    path = build_path(uri)
    Logger.debug("Mint connected, sending request to path: #{path}")

    request_headers =
      headers ++
        [
          {"accept", "text/event-stream"},
          {"content-type", "application/json"},
          {"content-length", to_string(byte_size(body))}
        ]

    method_string = method_to_string(method)
    Mint.HTTP.request(conn, method_string, path, request_headers, body)
  end

  defp method_to_string(:post), do: "POST"
  defp method_to_string(:get), do: "GET"
  defp method_to_string(:put), do: "PUT"
  defp method_to_string(:delete), do: "DELETE"
  defp method_to_string(method) when is_binary(method), do: method
  defp method_to_string(_), do: "POST"

  defp notify_waiting_clients(clients, response) do
    Enum.each(clients, fn from ->
      GenServer.reply(from, response)
    end)
  end

  # Private helpers

  defp handle_responses([], _ref, state), do: {:noreply, state}

  defp handle_responses([{:status, ref, status} | rest], ref, state) do
    Logger.debug("SSE: Received HTTP status #{status}")

    if status >= 200 and status < 300 do
      # Connection successful, notify any waiting clients
      if length(state.waiting_connected) > 0 do
        Enum.each(state.waiting_connected, fn from ->
          GenServer.reply(from, :ok)
        end)

        handle_responses(rest, ref, %{state | waiting_connected: []})
      else
        handle_responses(rest, ref, state)
      end
    else
      # Error status, notify waiting clients
      if length(state.waiting_connected) > 0 do
        Enum.each(state.waiting_connected, fn from ->
          GenServer.reply(from, {:error, "HTTP #{status}"})
        end)
      end

      {:noreply, %{state | error: "HTTP #{status}", waiting_connected: []}}
    end
  end

  defp handle_responses([{:headers, ref, _headers} | rest], ref, state) do
    handle_responses(rest, ref, state)
  end

  defp handle_responses([{:data, ref, data} | rest], ref, state) do
    # Append to buffer and process SSE events
    new_buffer = state.buffer <> data
    {events, remaining_buffer} = parse_sse_events(new_buffer)

    # Process events
    new_state =
      Enum.reduce(events, state, fn event, acc ->
        process_sse_event(event, acc)
      end)

    handle_responses(rest, ref, %{new_state | buffer: remaining_buffer})
  end

  defp handle_responses([{:done, ref} | _rest], ref, state) do
    {:noreply, %{state | done: true}}
  end

  defp handle_responses([_other | rest], ref, state) do
    handle_responses(rest, ref, state)
  end

  defp parse_sse_events(buffer) do
    # Split by double newline
    parts = String.split(buffer, "\n\n")

    case parts do
      [single] ->
        # No complete event yet
        {[], single}

      events ->
        # Last part might be incomplete
        {complete, [incomplete]} = Enum.split(events, -1)

        parsed_events =
          Enum.flat_map(complete, fn event_text ->
            if event_text != "" do
              [parse_single_event(event_text)]
            else
              []
            end
          end)

        {parsed_events, incomplete}
    end
  end

  defp parse_single_event(event_text) do
    event_text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [field, value] ->
          # Don't trim the value, only trim field and remove leading space from value
          clean_value = String.replace_prefix(value, " ", "")
          Map.put(acc, String.trim(field), clean_value)

        _ ->
          acc
      end
    end)
  end

  defp process_sse_event(%{"data" => data}, state) do
    trimmed_data = String.trim(data)

    # Handle [DONE] marker
    if trimmed_data == "[DONE]" do
      Logger.debug("SSE: Received [DONE] marker")
      %{state | done: true}
    else
      # Skip empty data lines
      if trimmed_data == "" do
        Logger.debug("SSE: Skipping empty data line")
        state
      else
        # Parse JSON data
        Logger.debug("SSE: Parsing data: #{inspect(data)}")

        case Jason.decode(data) do
          {:ok, parsed} ->
            Logger.debug("SSE: Queuing parsed event: #{inspect(parsed)}")
            queue = :queue.in(parsed, state.pending_chunks)
            %{state | pending_chunks: queue, received_valid_data: true}

          {:error, reason} ->
            Logger.debug("SSE: JSON parse error: #{inspect(reason)}")
            # Queue the parse error
            queue = :queue.in({:error, {:json_decode_error, reason}}, state.pending_chunks)
            %{state | pending_chunks: queue}
        end
      end
    end
  end

  defp process_sse_event(%{"event" => event_type} = event, state) do
    # Handle custom event types
    case event_type do
      "error" ->
        data = Map.get(event, "data", "")

        error =
          case Jason.decode(data) do
            {:ok, %{"message" => msg}} -> msg
            _ -> data
          end

        %{state | error: error}

      "done" ->
        %{state | done: true}

      _ ->
        # For other event types, process as data
        if Map.has_key?(event, "data") do
          process_sse_event(%{"data" => event["data"]}, state)
        else
          state
        end
    end
  end

  defp process_sse_event(_, state), do: state

  defp build_headers(config) do
    FalEx.Auth.get_request_headers(config)
  end

  defp scheme_to_atom("https"), do: :https
  defp scheme_to_atom("http"), do: :http
  defp scheme_to_atom(_), do: :https

  defp build_path(%URI{path: path, query: query}) do
    if query do
      "#{path || "/"}?#{query}"
    else
      path || "/"
    end
  end
end
