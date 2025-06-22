defmodule FalEx do
  @moduledoc """
  An Elixir client for fal.ai.

  FalEx provides a simple interface to run AI models on fal.ai's
  serverless platform. It supports synchronous execution, queued jobs,
  streaming responses, and real-time communication.

  ## Installation

  Add `fal_ex` to your list of dependencies in `mix.exs`:

      def deps do
        [
          {:fal_ex, "~> 0.1.0"}
        ]
      end

  ## Configuration

  Configure your API credentials using environment variables:

      export FAL_KEY="your-api-key"

  Or configure programmatically:

      FalEx.config(credentials: "your-api-key")

  ## Basic Usage

      # Simple synchronous execution
      {:ok, result} = FalEx.run("fal-ai/fast-sdxl",
        input: %{
          prompt: "A cute cat wearing a hat"
        }
      )

      # Queue-based execution with status updates
      {:ok, result} = FalEx.subscribe("fal-ai/fast-sdxl",
        input: %{prompt: "A mountain landscape"},
        on_queue_update: fn status -> IO.inspect(status) end
      )

      # Streaming responses
      stream = FalEx.stream("fal-ai/llava-v15",
        input: %{prompt: "Tell me a story"}
      )

      stream
      |> Stream.each(fn chunk -> IO.write(chunk.data) end)
      |> Stream.run()
  """

  use GenServer

  alias FalEx.{Client, Config, Streaming, Types}

  @type run_result :: {:ok, Types.result()} | {:error, term()}

  # Client state
  defmodule State do
    @moduledoc false
    defstruct [:config, :client]
  end

  # Singleton client process
  @name __MODULE__

  @doc """
  Starts the FalEx client process.

  This is typically called automatically by the application supervisor.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(opts) do
    config = Config.new(opts)
    client = Client.create(config)
    {:ok, %State{config: config, client: client}}
  end

  # Public API

  @doc """
  Configures the global FalEx client.

  ## Options

  See `FalEx.Config.new/1` for available options.

  ## Examples

      FalEx.config(credentials: System.get_env("FAL_KEY"))

      FalEx.config(
        credentials: {"key_id", "key_secret"},
        proxy_url: "/api/fal/proxy"
      )
  """
  def config(opts \\ []) do
    GenServer.call(@name, {:config, opts})
  end

  @doc """
  Runs a fal endpoint synchronously.

  ## Parameters

    * `endpoint_id` - The endpoint identifier (e.g., "fal-ai/fast-sdxl")
    * `opts` - Run options including `:input`

  ## Options

    * `:input` - The input payload for the model
    * `:path` - Optional path to append to the endpoint
    * `:method` - HTTP method (default: `:post`)
    * `:abort_signal` - Reference to abort the request

  ## Examples

      {:ok, result} = FalEx.run("fal-ai/fast-sdxl",
        input: %{
          prompt: "A beautiful sunset",
          image_size: "square"
        }
      )

  ## Notes

  This function blocks until the model execution completes. For long-running
  models, consider using `subscribe/2` instead.
  """
  @spec run(Types.endpoint_id(), keyword()) :: run_result()
  def run(endpoint_id, opts \\ []) do
    GenServer.call(@name, {:run, endpoint_id, opts}, :infinity)
  end

  @doc """
  Submits a request to the queue and subscribes to status updates.

  ## Parameters

    * `endpoint_id` - The endpoint identifier
    * `opts` - Run options plus queue-specific options

  ## Options

  All options from `run/2` plus:

    * `:on_queue_update` - Callback for status updates
    * `:logs` - Include logs in status updates (default: false)
    * `:webhook_url` - URL for webhook notifications
    * `:poll_interval` - Status poll interval in ms (default: 500)

  ## Examples

      {:ok, result} = FalEx.subscribe("fal-ai/fast-sdxl",
        input: %{prompt: "A cute dog"},
        logs: true,
        on_queue_update: fn status ->
          IO.puts("Status: " <> inspect(status.status))
        end
      )
  """
  @spec subscribe(Types.endpoint_id(), keyword()) :: run_result()
  def subscribe(endpoint_id, opts \\ []) do
    GenServer.call(@name, {:subscribe, endpoint_id, opts}, :infinity)
  end

  @doc """
  Streams partial results from a streaming-capable endpoint.

  Returns `{:ok, stream}` where `stream` is an Elixir Stream that yields data chunks as they arrive.

  ## Parameters

    * `endpoint_id` - The endpoint identifier
    * `opts` - Stream options including `:input`

  ## Examples

      # Stream image generation with progress updates
      {:ok, stream} = FalEx.stream("fal-ai/flux/dev",
        input: %{
          prompt: "a cat",
          seed: 6252023,
          image_size: "landscape_4_3",
          num_images: 4
        }
      )

      # Process each event as it arrives
      stream
      |> Stream.each(fn event ->
        IO.inspect(event, label: "Stream event")
      end)
      |> Stream.run()

      # Or collect all events and get the final result
      case FalEx.stream("fal-ai/flux/dev", input: %{prompt: "a cute robot"}) do
        {:ok, stream} ->
          events = Enum.to_list(stream)
          IO.puts("Received \#{length(events)} events")
          # The last event typically contains the final result

        {:error, reason} ->
          IO.puts("Error: \#{inspect(reason)}")
      end
  """
  @spec stream(Types.endpoint_id(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(endpoint_id, opts \\ []) do
    client = GenServer.call(@name, :get_streaming)

    case Streaming.stream(client, endpoint_id, opts) do
      {:ok, stream_handle} ->
        # Return a stream that will be lazily evaluated
        stream =
          Stream.resource(
            fn -> stream_handle end,
            &stream_next/1,
            &cleanup_stream/1
          )

        {:ok, stream}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Access the queue client for advanced queue operations.
  """
  def queue do
    GenServer.call(@name, :get_queue)
  end

  @doc """
  Access the storage client for file operations.
  """
  def storage do
    GenServer.call(@name, :get_storage)
  end

  @doc """
  Access the streaming client for advanced streaming operations.
  """
  def streaming do
    GenServer.call(@name, :get_streaming)
  end

  @doc """
  Access the realtime client for WebSocket connections.
  """
  def realtime do
    GenServer.call(@name, :get_realtime)
  end

  # GenServer callbacks

  @impl true
  def handle_call({:config, opts}, _from, _state) do
    new_config = Config.new(opts)
    new_client = Client.create(new_config)
    {:reply, :ok, %State{config: new_config, client: new_client}}
  end

  def handle_call({:run, endpoint_id, opts}, _from, %State{client: client} = state) do
    result = Client.run(client, endpoint_id, opts)
    {:reply, result, state}
  end

  def handle_call({:subscribe, endpoint_id, opts}, _from, %State{client: client} = state) do
    result = Client.subscribe(client, endpoint_id, opts)
    {:reply, result, state}
  end

  def handle_call(:get_queue, _from, %State{client: client} = state) do
    {:reply, client.queue, state}
  end

  def handle_call(:get_storage, _from, %State{client: client} = state) do
    {:reply, client.storage, state}
  end

  def handle_call(:get_streaming, _from, %State{client: client} = state) do
    {:reply, client.streaming, state}
  end

  def handle_call(:get_realtime, _from, %State{client: client} = state) do
    {:reply, client.realtime, state}
  end

  # Private stream helpers

  defp stream_next(stream) do
    case Streaming.next(stream) do
      {:ok, :done} -> {:halt, stream}
      {:ok, data} -> {[data], stream}
      {:error, _reason} -> {:halt, stream}
    end
  end

  defp cleanup_stream(stream) do
    Streaming.close(stream)
  end
end
