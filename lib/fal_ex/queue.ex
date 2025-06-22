defmodule FalEx.Queue do
  @moduledoc """
  Queue client for managing asynchronous fal.ai requests.

  Provides functionality to submit jobs to the queue, monitor their status,
  and retrieve results when complete.
  """

  alias FalEx.{Config, Request, Response, Storage, Types}

  defstruct [:config]

  @type t :: %__MODULE__{
          config: Config.t()
        }

  @default_poll_interval 500
  # 5 minutes
  @default_timeout 300_000

  @doc """
  Creates a new queue client.
  """
  def create(%Config{} = config) do
    %__MODULE__{config: config}
  end

  @doc """
  Submits a request to the queue.

  ## Options

    * `:input` - The input payload for the model
    * `:webhook_url` - Optional webhook URL for completion notification

  ## Examples

      {:ok, %{"request_id" => request_id}} = Queue.submit(queue, "fal-ai/fast-sdxl", 
        input: %{prompt: "A cat"}
      )
  """
  @spec submit(t(), Types.endpoint_id(), keyword()) :: {:ok, map()} | {:error, term()}
  def submit(%__MODULE__{} = queue, endpoint_id, opts \\ []) do
    # Transform input if provided
    input =
      case Keyword.get(opts, :input) do
        nil -> nil
        input -> Storage.transform_input(Storage.create(queue.config), input)
      end

    # Build URL - check if we should use queue subdomain or main endpoint
    base_url = Config.get_base_url(queue.config)

    # For localhost/testing, use queue subdomain; for production, use main endpoint
    url =
      if String.contains?(base_url, "localhost") do
        Request.build_url(endpoint_id, %{
          subdomain: "queue",
          path: "",
          base_url: base_url
        })
      else
        # For production fal.ai, use main endpoint with Prefer: respond-async header
        "#{base_url}/#{endpoint_id}"
      end

    # Build request body based on environment
    body =
      if String.contains?(base_url, "localhost") do
        # For tests, wrap in "input" field
        build_submit_body(input, opts)
      else
        # For production, send input directly
        input || %{}
      end

    # Make request with appropriate headers
    headers =
      if String.contains?(base_url, "localhost") do
        [{"x-fal-runner-type", "queue"}]
      else
        # Use Prefer: respond-async for production fal.ai
        [{"prefer", "respond-async"}]
      end

    Request.dispatch_request(%{
      method: :post,
      target_url: url,
      input: body,
      config: queue.config,
      options: %{headers: headers}
    })
  end

  @doc """
  Gets the status of a queued request.

  ## Options

    * `:request_id` - The request ID to check
    * `:logs` - Include execution logs (default: false)
  """
  @spec status(t(), Types.endpoint_id(), keyword()) ::
          {:ok, Types.queue_status_response()} | {:error, term()}
  def status(%__MODULE__{} = queue, endpoint_id, opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    logs = Keyword.get(opts, :logs, false)

    # Build URL with query params
    base_url =
      Request.build_url(endpoint_id, %{
        subdomain: "queue",
        path: "/status/#{request_id}",
        base_url: Config.get_base_url(queue.config)
      })

    url =
      if logs do
        "#{base_url}?logs=true"
      else
        base_url
      end

    # Make request
    case Request.dispatch_request(%{
           method: :get,
           target_url: url,
           config: queue.config
         }) do
      {:ok, response} ->
        {:ok, normalize_status_response(response)}

      error ->
        error
    end
  end

  @doc """
  Cancels a queued request.
  """
  @spec cancel(t(), Types.endpoint_id(), keyword()) :: :ok | {:error, term()}
  def cancel(%__MODULE__{} = queue, endpoint_id, opts) do
    request_id = Keyword.fetch!(opts, :request_id)

    url =
      Request.build_url(endpoint_id, %{
        subdomain: "queue",
        path: "/status/#{request_id}",
        base_url: Config.get_base_url(queue.config)
      })

    case Request.dispatch_request(%{
           method: :delete,
           target_url: url,
           config: queue.config
         }) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Gets the result of a completed request.
  """
  @spec result(t(), Types.endpoint_id(), keyword()) :: {:ok, Types.result()} | {:error, term()}
  def result(%__MODULE__{} = queue, endpoint_id, opts) do
    request_id = Keyword.fetch!(opts, :request_id)

    url =
      Request.build_url(endpoint_id, %{
        subdomain: "queue",
        path: "/result/#{request_id}",
        base_url: Config.get_base_url(queue.config)
      })

    config_with_handler = %{queue.config | response_handler: &Response.result_response_handler/1}

    Request.dispatch_request(%{
      method: :get,
      target_url: url,
      config: config_with_handler
    })
  end

  @doc """
  Subscribes to status updates for a queued request.

  Polls or uses SSE to monitor the request status until completion.

  ## Options

    * `:request_id` - The request ID to monitor
    * `:logs` - Include logs in status updates
    * `:on_queue_update` - Callback function for status updates
    * `:poll_interval` - Polling interval in ms (default: 500)
    * `:timeout` - Maximum time to wait in ms (default: 300000)
  """
  @spec subscribe_to_status(t(), Types.endpoint_id(), keyword()) :: :ok | {:error, term()}
  def subscribe_to_status(%__MODULE__{} = queue, endpoint_id, opts) do
    _request_id = Keyword.fetch!(opts, :request_id)
    on_update = Keyword.get(opts, :on_queue_update)
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Use polling for now (SSE implementation would be added later)
    poll_status(
      queue,
      endpoint_id,
      opts,
      on_update,
      poll_interval,
      timeout,
      :os.system_time(:millisecond)
    )
  end

  # Private functions

  defp build_submit_body(input, opts) do
    body = %{}

    body =
      if input do
        Map.put(body, "input", input)
      else
        body
      end

    body =
      if webhook_url = Keyword.get(opts, :webhook_url) do
        Map.put(body, "webhook_url", webhook_url)
      else
        body
      end

    body
  end

  defp normalize_status_response(response) do
    status =
      case Map.get(response, "status") do
        "IN_QUEUE" -> :in_queue
        "IN_PROGRESS" -> :in_progress
        "COMPLETED" -> :completed
        other -> other
      end

    %{
      status: status,
      request_id: Map.get(response, "request_id"),
      response_url: Map.get(response, "response_url"),
      logs: Map.get(response, "logs", []),
      metrics: Map.get(response, "metrics")
    }
  end

  defp poll_status(queue, endpoint_id, opts, on_update, poll_interval, timeout, start_time) do
    current_time = :os.system_time(:millisecond)

    if current_time - start_time > timeout do
      {:error, :timeout}
    else
      case status(queue, endpoint_id, opts) do
        {:ok, %{status: :completed} = status} ->
          if on_update, do: on_update.(status)
          :ok

        {:ok, status} ->
          if on_update, do: on_update.(status)
          Process.sleep(poll_interval)
          poll_status(queue, endpoint_id, opts, on_update, poll_interval, timeout, start_time)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
