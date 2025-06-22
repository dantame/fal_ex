defmodule FalEx.TestHelpers do
  @moduledoc """
  Common test helpers and fixtures for FalEx tests.
  """

  import ExUnit.Assertions

  defmodule DummyServer do
    @moduledoc """
    A dummy GenServer for testing purposes.
    """
    use GenServer

    def init(_), do: {:ok, %{}}
  end

  @doc """
  Returns a mock successful run response
  """
  def mock_run_response do
    %{
      "data" => %{
        "prediction" => "test result",
        "confidence" => 0.95
      },
      "request_id" => "req_123456",
      "status" => "completed"
    }
  end

  @doc """
  Returns a mock error response
  """
  def mock_error_response(status_code \\ 500, message \\ "Internal Server Error") do
    %{
      "error" => %{
        "message" => message,
        "code" => "ERROR_#{status_code}"
      }
    }
  end

  @doc """
  Returns a mock queue submit response
  """
  def mock_queue_submit_response do
    %{
      "request_id" => "req_queue_123456",
      "status_url" => "/queue/requests/req_queue_123456/status",
      "cancel_url" => "/queue/requests/req_queue_123456/cancel",
      "logs_url" => "/queue/requests/req_queue_123456/logs"
    }
  end

  @doc """
  Returns a mock queue status response (in_queue)
  """
  def mock_queue_status_in_queue do
    %{
      "status" => "IN_QUEUE",
      "queue_position" => 5,
      "request_id" => "req_queue_123456"
    }
  end

  @doc """
  Returns a mock queue status response (in_progress)
  """
  def mock_queue_status_in_progress do
    %{
      "status" => "IN_PROGRESS",
      "logs" => [
        %{"timestamp" => "2024-01-01T12:00:00Z", "message" => "Starting processing..."},
        %{"timestamp" => "2024-01-01T12:00:05Z", "message" => "Loading model..."}
      ],
      "request_id" => "req_queue_123456"
    }
  end

  @doc """
  Returns a mock queue status response (completed)
  """
  def mock_queue_status_completed do
    %{
      "status" => "COMPLETED",
      "completed_at" => "2024-01-01T12:01:00Z",
      "request_id" => "req_queue_123456"
    }
  end

  @doc """
  Returns a mock queue result response
  """
  def mock_queue_result_response do
    %{
      "data" => %{
        "output" => "Generated result from queue",
        "metadata" => %{"processing_time" => 45.2}
      },
      "request_id" => "req_queue_123456",
      "status" => "completed"
    }
  end

  @doc """
  Returns a mock storage upload response
  """
  def mock_storage_upload_response do
    %{
      "file_url" => "https://storage.fal.ai/files/abc123/image.png",
      "file_name" => "image.png",
      "content_type" => "image/png"
    }
  end

  @doc """
  Returns mock SSE (Server-Sent Events) chunks
  """
  def mock_sse_chunks do
    [
      "data: {\"event\":\"start\",\"request_id\":\"req_stream_123\"}\n\n",
      "data: {\"event\":\"progress\",\"progress\":0.25,\"message\":\"Processing...\"}\n\n",
      "data: {\"event\":\"progress\",\"progress\":0.75,\"message\":\"Almost done...\"}\n\n",
      "data: {\"event\":\"complete\",\"result\":{\"output\":\"Streaming result\"}}\n\n",
      "data: [DONE]\n\n"
    ]
  end

  @doc """
  Returns a mock WebSocket frame
  """
  def mock_websocket_frame(type \\ :text, data \\ nil) do
    data = data || Jason.encode!(%{type: "message", data: "test"})
    {type, data}
  end

  @doc """
  Builds a Bypass route that returns JSON
  """
  def json_response(conn, status_code, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status_code, Jason.encode!(body))
  end

  @doc """
  Builds a Bypass route that streams SSE
  """
  def sse_response(conn, chunks) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk, conn ->
      case Plug.Conn.chunk(conn, chunk) do
        {:ok, conn} -> conn
        {:error, :closed} -> conn
      end
    end)
  end

  @doc """
  Asserts that a request has the expected headers
  """
  def assert_has_headers(conn, expected_headers) do
    actual_headers = conn.req_headers |> Enum.into(%{})

    Enum.each(expected_headers, fn {key, value} ->
      assert actual_headers[key] == value,
             "Expected header #{key} to be #{value}, got #{inspect(actual_headers[key])}"
    end)
  end

  @doc """
  Asserts that a request has valid authorization
  """
  def assert_has_auth(conn, expected_key \\ "test_api_key") do
    assert_has_headers(conn, %{"authorization" => "Key #{expected_key}"})
  end

  @doc """
  Creates a test configuration
  """
  def test_config(overrides \\ %{}) do
    port = overrides[:bypass_port] || 4001

    config_opts = [
      credentials: overrides[:api_key] || "test_api_key",
      base_url: overrides[:api_url] || "http://localhost:#{port}"
    ]

    # Add any other overrides
    config_opts =
      Enum.reduce(overrides, config_opts, fn
        {:api_key, value}, acc -> Keyword.put(acc, :credentials, value)
        {:api_url, value}, acc -> Keyword.put(acc, :base_url, value)
        {:bypass_port, _}, acc -> acc
        {key, value}, acc -> Keyword.put(acc, key, value)
      end)

    FalEx.Config.new(config_opts)
  end

  @doc """
  Waits for an async task with timeout
  """
  def wait_for_async(task, timeout \\ 5000) do
    Task.await(task, timeout)
  end

  @doc """
  Creates a temporary file for testing
  """
  def create_temp_file(content, extension \\ "txt") do
    path = Path.join(System.tmp_dir!(), "fal_ex_test_#{:rand.uniform(1_000_000)}.#{extension}")
    File.write!(path, content)
    path
  end

  @doc """
  Cleans up temporary test files
  """
  def cleanup_temp_file(path) do
    File.rm(path)
  end
end
