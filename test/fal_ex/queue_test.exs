defmodule FalEx.QueueTest do
  use ExUnit.Case, async: true

  alias FalEx.Config
  alias FalEx.Fixtures
  alias FalEx.Queue
  alias FalEx.TestHelpers

  setup do
    bypass = Bypass.open()

    config =
      Config.new(
        credentials: "test_api_key",
        base_url: "http://localhost:#{bypass.port}"
      )

    queue = Queue.create(config)

    {:ok, bypass: bypass, config: config, queue: queue}
  end

  describe "submit/3" do
    test "successfully submits a job to the queue", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      input = Fixtures.image_generation_input()
      expected_response = TestHelpers.mock_queue_submit_response()

      Bypass.expect_once(bypass, "POST", "/queue/#{endpoint_id}", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-fal-runner-type") == ["queue"]
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Key test_api_key"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["input"] == input

        TestHelpers.json_response(conn, 200, expected_response)
      end)

      assert {:ok, response} = Queue.submit(queue, endpoint_id, input: input)
      assert response["request_id"] == "req_queue_123456"
      assert response["status_url"] =~ "/status"
      assert response["cancel_url"] =~ "/cancel"
    end

    test "handles queue submission errors", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      Bypass.expect_once(bypass, "POST", "/queue/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 503, %{
          "error" => %{
            "message" => "Queue is full",
            "code" => "QUEUE_FULL"
          }
        })
      end)

      assert {:error,
              %FalEx.Response.ApiError{status: 503, body: %{"error" => %{"code" => "QUEUE_FULL"}}}} =
               Queue.submit(queue, endpoint_id, input: %{})
    end

    test "includes webhook URL when provided", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      input = Fixtures.image_generation_input()
      webhook_url = "https://example.com/webhook"

      Bypass.expect_once(bypass, "POST", "/queue/#{endpoint_id}", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["webhook_url"] == webhook_url
        assert decoded["input"]["prompt"] == input["prompt"]

        TestHelpers.json_response(conn, 200, TestHelpers.mock_queue_submit_response())
      end)

      assert {:ok, _} = Queue.submit(queue, endpoint_id, input: input, webhook_url: webhook_url)
    end
  end

  describe "status/3" do
    test "successfully retrieves job status - in queue", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"
      expected_response = TestHelpers.mock_queue_status_in_queue()

      Bypass.expect_once(bypass, "GET", "/queue/#{endpoint_id}/status/#{request_id}", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Key test_api_key"]
        TestHelpers.json_response(conn, 200, expected_response)
      end)

      assert {:ok, response} = Queue.status(queue, endpoint_id, request_id: request_id)
      assert response[:status] == :in_queue
      assert response[:request_id] == request_id
    end

    test "successfully retrieves job status - in progress", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"
      expected_response = TestHelpers.mock_queue_status_in_progress()

      Bypass.expect_once(bypass, "GET", "/queue/#{endpoint_id}/status/#{request_id}", fn conn ->
        TestHelpers.json_response(conn, 200, expected_response)
      end)

      assert {:ok, response} = Queue.status(queue, endpoint_id, request_id: request_id)
      assert response[:status] == :in_progress
      assert is_list(response[:logs])
      assert length(response[:logs]) == 2
    end

    test "successfully retrieves job status - completed", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"
      expected_response = TestHelpers.mock_queue_status_completed()

      Bypass.expect_once(bypass, "GET", "/queue/#{endpoint_id}/status/#{request_id}", fn conn ->
        TestHelpers.json_response(conn, 200, expected_response)
      end)

      assert {:ok, response} = Queue.status(queue, endpoint_id, request_id: request_id)
      assert response[:status] == :completed
      assert response[:request_id] == request_id
    end

    test "includes logs when requested", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"

      Bypass.expect_once(
        bypass,
        "GET",
        "/queue/#{endpoint_id}/status/#{request_id}",
        fn conn ->
          assert conn.query_string == "logs=true"
          TestHelpers.json_response(conn, 200, TestHelpers.mock_queue_status_in_progress())
        end
      )

      assert {:ok, response} =
               Queue.status(queue, endpoint_id, request_id: request_id, logs: true)

      assert is_list(response[:logs])
    end

    test "handles job not found", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "non_existent_request"

      Bypass.expect_once(bypass, "GET", "/queue/#{endpoint_id}/status/#{request_id}", fn conn ->
        TestHelpers.json_response(conn, 404, %{
          "error" => %{
            "message" => "Request not found",
            "code" => "REQUEST_NOT_FOUND"
          }
        })
      end)

      assert {:error, %FalEx.Response.ApiError{status: 404}} =
               Queue.status(queue, endpoint_id, request_id: request_id)
    end
  end

  describe "result/3" do
    test "successfully retrieves job result", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"
      expected_response = TestHelpers.mock_queue_result_response()

      Bypass.expect_once(bypass, "GET", "/queue/#{endpoint_id}/result/#{request_id}", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Key test_api_key"]
        TestHelpers.json_response(conn, 200, expected_response)
      end)

      assert {:ok, response} = Queue.result(queue, endpoint_id, request_id: request_id)
      assert response["data"]["output"] == "Generated result from queue"
      assert response["data"]["metadata"]["processing_time"] == 45.2
    end

    test "handles job still in progress", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"

      Bypass.expect_once(bypass, "GET", "/queue/#{endpoint_id}/result/#{request_id}", fn conn ->
        TestHelpers.json_response(conn, 202, %{
          "status" => "IN_PROGRESS",
          "message" => "Job is still processing"
        })
      end)

      # 202 is actually a success status, not an error
      assert {:ok, %{"status" => "IN_PROGRESS"}} =
               Queue.result(queue, endpoint_id, request_id: request_id)
    end

    test "handles failed job", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"

      Bypass.expect_once(bypass, "GET", "/queue/#{endpoint_id}/result/#{request_id}", fn conn ->
        TestHelpers.json_response(conn, 200, %{
          "status" => "FAILED",
          "error" => %{
            "message" => "Model execution failed",
            "code" => "EXECUTION_FAILED"
          }
        })
      end)

      assert {:ok, response} = Queue.result(queue, endpoint_id, request_id: request_id)
      assert response["status"] == "FAILED"
      assert response["error"]["code"] == "EXECUTION_FAILED"
    end
  end

  describe "cancel/3" do
    test "successfully cancels a queued job", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"

      Bypass.expect_once(
        bypass,
        "DELETE",
        "/queue/#{endpoint_id}/status/#{request_id}",
        fn conn ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Key test_api_key"]

          TestHelpers.json_response(conn, 200, %{
            "status" => "CANCELLED",
            "message" => "Job cancelled successfully"
          })
        end
      )

      assert :ok = Queue.cancel(queue, endpoint_id, request_id: request_id)
    end

    test "handles cancellation of completed job", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"

      Bypass.expect_once(
        bypass,
        "DELETE",
        "/queue/#{endpoint_id}/status/#{request_id}",
        fn conn ->
          TestHelpers.json_response(conn, 400, %{
            "error" => %{
              "message" => "Cannot cancel completed job",
              "code" => "INVALID_STATE"
            }
          })
        end
      )

      assert {:error, %FalEx.Response.ValidationError{}} =
               Queue.cancel(queue, endpoint_id, request_id: request_id)
    end
  end

  describe "subscribe_to_status/3" do
    test "polls status updates until completion", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"

      # Set up sequence of status responses
      status_sequence = [
        TestHelpers.mock_queue_status_in_queue(),
        TestHelpers.mock_queue_status_in_progress(),
        TestHelpers.mock_queue_status_completed()
      ]

      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "GET", "/queue/#{endpoint_id}/status/#{request_id}", fn conn ->
        index = Agent.get_and_update(agent, fn i -> {i, i + 1} end)
        response = Enum.at(status_sequence, index)
        TestHelpers.json_response(conn, 200, response)
      end)

      _updates = []

      callback = fn update ->
        send(self(), {:status_update, update})
      end

      assert :ok =
               Queue.subscribe_to_status(queue, endpoint_id,
                 request_id: request_id,
                 on_queue_update: callback,
                 poll_interval: 10
               )

      # Collect status updates
      updates_received = receive_updates([])

      assert length(updates_received) == 3
      assert List.first(updates_received)[:status] == :in_queue
      assert List.last(updates_received)[:status] == :completed

      Agent.stop(agent)
    end

    test "handles errors during polling", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"

      Bypass.expect_once(bypass, "GET", "/queue/#{endpoint_id}/status/#{request_id}", fn conn ->
        TestHelpers.json_response(conn, 500, TestHelpers.mock_error_response())
      end)

      assert {:error, _} = Queue.subscribe_to_status(queue, endpoint_id, request_id: request_id)
    end

    test "respects polling interval", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"

      # Track timing between requests
      {:ok, agent} = Agent.start_link(fn -> [] end)

      Bypass.expect(bypass, "GET", "/queue/#{endpoint_id}/status/#{request_id}", fn conn ->
        Agent.update(agent, fn times -> [System.monotonic_time(:millisecond) | times] end)

        # Return completed status to end polling quickly
        TestHelpers.json_response(conn, 200, TestHelpers.mock_queue_status_completed())
      end)

      Queue.subscribe_to_status(queue, endpoint_id,
        request_id: request_id,
        poll_interval: 100
      )

      times = Agent.get(agent, & &1) |> Enum.reverse()

      # Should only have one request since we return completed immediately
      assert length(times) == 1

      Agent.stop(agent)
    end

    test "handles timeout", %{bypass: bypass, queue: queue} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      request_id = "req_queue_123456"

      # Always return in_progress to simulate timeout
      Bypass.expect(bypass, "GET", "/queue/#{endpoint_id}/status/#{request_id}", fn conn ->
        TestHelpers.json_response(conn, 200, TestHelpers.mock_queue_status_in_progress())
      end)

      assert {:error, :timeout} =
               Queue.subscribe_to_status(queue, endpoint_id,
                 request_id: request_id,
                 timeout: 100
               )
    end

    defp receive_updates(acc) do
      receive do
        {:status_update, update} -> receive_updates([update | acc])
      after
        100 -> Enum.reverse(acc)
      end
    end
  end

  describe "URL construction" do
    test "handles different endpoint ID formats", %{bypass: bypass, queue: queue} do
      test_cases = [
        {"fal-ai/fast-sdxl", "/queue/fal-ai/fast-sdxl"},
        {"110602490-lora", "/queue/110602490-lora"},
        {"custom/model-v2", "/queue/custom/model-v2"}
      ]

      Enum.each(test_cases, fn {endpoint_id, expected_path} ->
        Bypass.expect_once(bypass, "POST", expected_path, fn conn ->
          TestHelpers.json_response(conn, 200, TestHelpers.mock_queue_submit_response())
        end)

        assert {:ok, _} = Queue.submit(queue, endpoint_id, input: %{})
      end)
    end
  end
end
