defmodule FalEx.Realtime do
  @moduledoc """
  Realtime client for WebSocket connections to fal.ai.

  Provides bidirectional communication with AI models that support
  real-time interaction.
  """

  alias FalEx.{Auth, Config}
  alias FalEx.Realtime.Connection

  defstruct [:config]

  @type t :: %__MODULE__{
          config: Config.t()
        }

  @doc """
  Creates a new realtime client.
  """
  def create(%Config{} = config) do
    %__MODULE__{config: config}
  end

  @doc """
  Connects to a realtime endpoint.

  ## Options

    * `:connection_key` - Reuse existing connection with this key
    * `:throttle_interval` - Throttle messages (ms, default: 128)
    * `:on_message` - Callback for incoming messages
    * `:on_error` - Callback for errors
    * `:on_close` - Callback for connection close

  ## Examples

      {:ok, conn} = Realtime.connect(realtime, "fal-ai/llava-next",
        on_message: fn message ->
          IO.inspect(message)
        end
      )
  """
  def connect(%__MODULE__{} = realtime, app_id, opts \\ []) do
    # Get connection token
    case get_connection_token(realtime.config, app_id) do
      {:ok, token, url} ->
        # Start WebSocket connection
        Connection.start_link(%{
          url: url,
          token: token,
          config: realtime.config,
          app_id: app_id,
          opts: Enum.into(opts, %{})
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends a message through the realtime connection.
  """
  def send(connection, message) do
    GenServer.call(connection, {:send, message})
  end

  @doc """
  Closes a realtime connection.
  """
  def close(connection) when is_pid(connection) do
    if Process.alive?(connection) do
      GenServer.stop(connection)
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  # Private functions

  defp get_connection_token(config, app_id) do
    # For client connections, get temporary token
    case Auth.create_temporary_token(config, allowed_apps: [app_id]) do
      {:ok, token} ->
        # Build WebSocket URL
        base_url = Config.get_base_url(config)

        ws_url =
          base_url
          |> String.replace("https://", "wss://")
          |> String.replace("http://", "ws://")

        url = "#{ws_url}/realtime/#{app_id}/ws"

        {:ok, token, url}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule FalEx.Realtime.Connection do
  @moduledoc false

  use WebSockex

  require Logger

  defmodule State do
    @moduledoc false
    defstruct [
      :config,
      :app_id,
      :token,
      :on_message,
      :on_error,
      :on_close,
      :throttle_interval,
      :last_send_time,
      :msgpack_enabled
    ]
  end

  def start_link(opts) do
    url = build_url(opts.url, opts.token)

    state = %State{
      config: opts.config,
      app_id: opts.app_id,
      token: opts.token,
      on_message: opts.opts[:on_message],
      on_error: opts.opts[:on_error],
      on_close: opts.opts[:on_close],
      throttle_interval: opts.opts[:throttle_interval] || 128,
      last_send_time: 0,
      msgpack_enabled: opts.opts[:msgpack] || false
    }

    WebSockex.start_link(url, __MODULE__, state)
  end

  # Client API

  def send(pid, message) do
    WebSockex.send_frame(pid, encode_message(message))
  end

  # WebSockex callbacks

  @impl true
  def handle_frame({:text, msg}, state) do
    handle_message(msg, state)
  end

  def handle_frame({:binary, msg}, state) do
    # Handle MessagePack binary frames
    if state.msgpack_enabled do
      case Msgpax.unpack(msg) do
        {:ok, unpacked} ->
          handle_message(unpacked, state)

        {:error, reason} ->
          Logger.error("Failed to unpack MessagePack: #{inspect(reason)}")
          {:ok, state}
      end
    else
      handle_message(msg, state)
    end
  end

  @impl true
  def handle_cast({:send, message}, state) do
    # Apply throttling
    now = :os.system_time(:millisecond)

    if now - state.last_send_time >= state.throttle_interval do
      frame = encode_frame(message, state)
      {:reply, frame, %{state | last_send_time: now}}
    else
      # Queue for later
      Process.send_after(self(), {:delayed_send, message}, state.throttle_interval)
      {:ok, state}
    end
  end

  @impl true
  def handle_info({:delayed_send, message}, state) do
    frame = encode_frame(message, state)
    {:reply, frame, %{state | last_send_time: :os.system_time(:millisecond)}}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    if state.on_close do
      state.on_close.(reason)
    end

    # Attempt reconnection with new token
    case FalEx.Auth.create_temporary_token(state.config, allowed_apps: [state.app_id]) do
      {:ok, new_token} ->
        {:reconnect, %{state | token: new_token}}

      {:error, _} ->
        {:ok, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    if state.on_close do
      state.on_close.(reason)
    end

    :ok
  end

  # Private helpers

  defp build_url(base_url, token) do
    "#{base_url}?token=#{token}"
  end

  defp encode_message(message) when is_binary(message), do: {:text, message}
  defp encode_message(message), do: {:text, Jason.encode!(message)}

  defp encode_frame(message, %State{msgpack_enabled: true}) do
    {:binary, Msgpax.pack!(message)}
  end

  defp encode_frame(message, _state) do
    {:text, Jason.encode!(message)}
  end

  defp handle_message(msg, state) do
    parsed =
      case msg do
        msg when is_binary(msg) ->
          case Jason.decode(msg) do
            {:ok, parsed} -> parsed
            {:error, _} -> %{"data" => msg}
          end

        msg ->
          msg
      end

    cond do
      Map.has_key?(parsed, "error") ->
        if state.on_error do
          state.on_error.(parsed["error"])
        end

      state.on_message ->
        state.on_message.(parsed)

      true ->
        Logger.debug("Unhandled realtime message: #{inspect(parsed)}")
    end

    {:ok, state}
  end
end
