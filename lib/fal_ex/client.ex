defmodule FalEx.Client do
  @moduledoc """
  The main client implementation for FalEx.

  This module creates and manages the various sub-clients (queue, storage, streaming, realtime)
  and provides the core run/subscribe functionality.
  """

  alias FalEx.{Config, Queue, Realtime, Request, Response, Storage, Streaming, Types}

  defstruct [:config, :queue, :storage, :streaming, :realtime]

  @type t :: %__MODULE__{
          config: Config.t(),
          queue: Queue.t(),
          storage: Storage.t(),
          streaming: Streaming.t(),
          realtime: Realtime.t()
        }

  @doc """
  Creates a new FalEx client with the given configuration.
  """
  @spec create(Config.t()) :: t()
  def create(%Config{} = config) do
    %__MODULE__{
      config: config,
      queue: Queue.create(config),
      storage: Storage.create(config),
      streaming: Streaming.create(config),
      realtime: Realtime.create(config)
    }
  end

  @doc """
  Runs a fal endpoint synchronously.
  """
  @spec run(t(), Types.endpoint_id(), keyword()) ::
          {:ok, Types.result()} | {:error, term()}
  def run(%__MODULE__{} = client, endpoint_id, opts \\ []) do
    # Transform input if needed
    input =
      case Keyword.get(opts, :input) do
        nil -> nil
        input -> Storage.transform_input(client.storage, input)
      end

    # Build request options
    base_path = Keyword.get(opts, :path, "")
    # Don't encode the endpoint ID - let Tesla handle URL encoding
    full_path =
      if base_path == "", do: "/v1/run/#{endpoint_id}", else: "#{base_path}/#{endpoint_id}"

    request_opts = %{
      method: Keyword.get(opts, :method, :post),
      target_url: "#{Config.get_base_url(client.config)}#{full_path}",
      input: input,
      config: client.config,
      options: %{
        signal: Keyword.get(opts, :abort_signal),
        timeout: Keyword.get(opts, :timeout)
      }
    }

    # Dispatch request with result handler
    config_with_handler = %{client.config | response_handler: &Response.result_response_handler/1}

    Request.dispatch_request(%{request_opts | config: config_with_handler})
  end

  @doc """
  Submits a request to the queue and subscribes to updates.
  """
  @spec subscribe(t(), Types.endpoint_id(), keyword()) :: {:ok, Types.result()} | {:error, term()}
  def subscribe(%__MODULE__{} = client, endpoint_id, opts \\ []) do
    # Submit to queue
    case Queue.submit(client.queue, endpoint_id, opts) do
      {:ok, %{"request_id" => request_id}} ->
        # Notify enqueue callback if provided
        if on_enqueue = Keyword.get(opts, :on_enqueue) do
          on_enqueue.(request_id)
        end

        # Subscribe to status updates
        subscribe_opts = Keyword.put(opts, :request_id, request_id)

        case Queue.subscribe_to_status(client.queue, endpoint_id, subscribe_opts) do
          :ok ->
            # Get final result
            Queue.result(client.queue, endpoint_id, request_id: request_id)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, result} ->
        # Request completed synchronously, return the result directly
        # Notify on_queue_update callback with completed status if provided
        if on_update = Keyword.get(opts, :on_queue_update) do
          on_update.(%{status: :completed, result: result})
        end

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
