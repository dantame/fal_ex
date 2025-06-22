defmodule FalEx.StreamingTest do
  use ExUnit.Case, async: true

  alias FalEx.Fixtures
  alias FalEx.Streaming
  alias FalEx.TestHelpers

  setup do
    bypass = Bypass.open()
    config = TestHelpers.test_config(%{bypass_port: bypass.port})
    streaming = Streaming.create(config)

    {:ok, bypass: bypass, config: config, streaming: streaming}
  end

  describe "stream/3" do
    test "successfully creates a streaming connection", %{
      bypass: bypass,
      config: config,
      streaming: streaming
    } do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      input = Fixtures.image_generation_input()

      ref = make_ref()
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        send(test_pid, {ref, :request_received})
        TestHelpers.assert_has_auth(conn, FalEx.Config.resolve_credentials(config))

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == input

        # Return SSE stream
        TestHelpers.sse_response(conn, TestHelpers.mock_sse_chunks())
      end)

      assert {:ok, stream_pid} = Streaming.stream(streaming, endpoint_id, input: input)
      assert is_pid(stream_pid)

      # Wait for request to be received
      assert_receive {^ref, :request_received}, 1000

      # Give the stream a moment to process the initial data
      Process.sleep(50)

      # Clean up
      Streaming.close(stream_pid)
    end

    test "handles connection errors", %{config: config} do
      bad_config = %{config | base_url: "http://localhost:65500"}

      assert {:error, _reason} =
               Streaming.stream(Streaming.create(bad_config), "test/model", [])
    end

    test "handles authentication errors", %{bypass: bypass} do
      config = TestHelpers.test_config(%{bypass_port: bypass.port, api_key: "invalid"})
      streaming = Streaming.create(config)
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      ref = make_ref()
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        send(test_pid, {ref, :request_received})
        TestHelpers.json_response(conn, 401, Fixtures.auth_error())
      end)

      {:ok, stream_pid} = Streaming.stream(streaming, endpoint_id, [])

      # Wait for auth error
      assert_receive {^ref, :request_received}, 1000

      # The stream should error on next call
      assert {:error, _} = Streaming.next(stream_pid)

      # Clean up
      Streaming.close(stream_pid)
    end

    test "handles non-SSE responses", %{bypass: bypass, config: _config, streaming: streaming} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      ref = make_ref()
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        send(test_pid, {ref, :request_received})
        # Return JSON instead of SSE
        TestHelpers.json_response(conn, 200, %{"error" => "Not a stream"})
      end)

      {:ok, stream_pid} = Streaming.stream(streaming, endpoint_id, [])

      # Wait for response
      assert_receive {^ref, :request_received}, 1000

      # Should get closed error when trying to read
      assert {:error, :closed} = Streaming.next(stream_pid)

      # Clean up
      Streaming.close(stream_pid)
    end
  end

  describe "next/1" do
    test "receives SSE events in order", %{bypass: bypass, config: _config, streaming: streaming} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      events = Fixtures.streaming_events()

      # Convert events to SSE format
      sse_chunks =
        Enum.map(events, fn event ->
          "data: #{Jason.encode!(event)}\n\n"
        end) ++ ["data: [DONE]\n\n"]

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        TestHelpers.sse_response(conn, sse_chunks)
      end)

      {:ok, stream} = Streaming.stream(streaming, endpoint_id, [])

      # Collect all events
      received_events = collect_stream_events(stream, [])

      # Verify events
      assert length(received_events) == length(events)

      Enum.zip(events, received_events)
      |> Enum.each(fn {expected, received} ->
        assert received["type"] == expected["type"]
        assert received["data"] == expected["data"]
      end)
    end

    test "handles [DONE] marker", %{bypass: bypass, config: _config, streaming: streaming} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      sse_chunks = [
        "data: {\"type\":\"start\",\"data\":{}}\n\n",
        "data: [DONE]\n\n"
      ]

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        TestHelpers.sse_response(conn, sse_chunks)
      end)

      {:ok, stream} = Streaming.stream(streaming, endpoint_id, [])

      # First event
      assert {:ok, %{"type" => "start"}} = Streaming.next(stream)

      # Done marker
      assert {:ok, :done} = Streaming.next(stream)

      # After done, should return done
      assert {:ok, :done} = Streaming.next(stream)
    end

    test "handles empty data lines", %{bypass: bypass, config: _config, streaming: streaming} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      sse_chunks = [
        "data: {\"event\":\"test\"}\n\n",
        # Empty data line - should be skipped
        "data: \n\n",
        "data: {\"event\":\"test2\"}\n\n",
        "data: [DONE]\n\n"
      ]

      ref = make_ref()
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        send(test_pid, {ref, :request_received})
        TestHelpers.sse_response(conn, sse_chunks)
      end)

      {:ok, stream} = Streaming.stream(streaming, endpoint_id, [])

      # Wait for request
      assert_receive {^ref, :request_received}, 1000

      # Should skip empty data and get valid events
      assert {:ok, %{"event" => "test"}} = Streaming.next(stream)
      assert {:ok, %{"event" => "test2"}} = Streaming.next(stream)
      assert {:ok, :done} = Streaming.next(stream)
    end

    test "handles malformed JSON", %{bypass: bypass, config: _config, streaming: streaming} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      sse_chunks = [
        "data: {\"valid\":\"json\"}\n\n",
        "data: {invalid json}\n\n",
        "data: {\"valid2\":\"json\"}\n\n",
        "data: [DONE]\n\n"
      ]

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        TestHelpers.sse_response(conn, sse_chunks)
      end)

      {:ok, stream} = Streaming.stream(streaming, endpoint_id, [])

      assert {:ok, %{"valid" => "json"}} = Streaming.next(stream)
      # Malformed JSON
      assert {:error, _} = Streaming.next(stream)
      assert {:ok, %{"valid2" => "json"}} = Streaming.next(stream)
      assert {:ok, :done} = Streaming.next(stream)
    end

    test "handles connection close", %{bypass: bypass, config: _config, streaming: streaming} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      ref = make_ref()
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        send(test_pid, {ref, :request_received})

        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        # Send one chunk then close
        {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"test\":1}\n\n")
        # Simulate connection close
        conn
      end)

      {:ok, stream} = Streaming.stream(streaming, endpoint_id, [])

      # Wait for request
      assert_receive {^ref, :request_received}, 1000

      assert {:ok, %{"test" => 1}} = Streaming.next(stream)
      # Connection closed after sending valid data, should get done
      assert {:ok, :done} = Streaming.next(stream)
    end

    test "timeout on next", %{bypass: bypass, config: _config, streaming: streaming} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      ref = make_ref()
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        send(test_pid, {ref, :request_received})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

        # Don't send any data
      end)

      {:ok, stream} = Streaming.stream(streaming, endpoint_id, [])

      # Wait for request
      assert_receive {^ref, :request_received}, 1000

      # Should timeout waiting for data
      # Try to get next with a short timeout by wrapping in Task
      task = Task.async(fn -> Streaming.next(stream) end)

      case Task.yield(task, 100) || Task.shutdown(task) do
        {:ok, result} ->
          # If we got a result, it should be an error or timeout
          assert match?({:error, _}, result)

        nil ->
          # Task timed out, which is what we expect
          assert true
      end

      # Clean up
      Streaming.close(stream)
    end
  end

  describe "close/1" do
    test "properly closes the stream", %{bypass: bypass, config: _config, streaming: streaming} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      ref = make_ref()
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        send(test_pid, {ref, :request_received})
        TestHelpers.sse_response(conn, ["data: {\"test\":1}\n\n"])
      end)

      {:ok, stream} = Streaming.stream(streaming, endpoint_id, [])
      assert is_pid(stream)

      # Wait for request
      assert_receive {^ref, :request_received}, 1000

      # Close stream
      :ok = Streaming.close(stream)

      # Process should be dead
      refute Process.alive?(stream)

      # Further operations should fail
      assert {:error, :closed} = Streaming.next(stream)
    end

    test "idempotent close", %{bypass: bypass, config: _config, streaming: streaming} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      ref = make_ref()
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        send(test_pid, {ref, :request_received})
        TestHelpers.sse_response(conn, [])
      end)

      {:ok, stream} = Streaming.stream(streaming, endpoint_id, [])

      # Wait for request
      assert_receive {^ref, :request_received}, 1000

      # Multiple closes should be ok
      :ok = Streaming.close(stream)
      :ok = Streaming.close(stream)
      :ok = Streaming.close(stream)
    end
  end

  describe "SSE parsing" do
    test "handles various SSE formats", %{bypass: bypass, config: _config, streaming: streaming} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      sse_chunks = [
        # Standard format
        "data: {\"event\":\"standard\"}\n\n",
        # Multiple newlines
        "data: {\"event\":\"multiple\"}\n\n\n",
        # Event type (should be ignored)
        "event: custom\ndata: {\"event\":\"with_type\"}\n\n",
        # Comment (should be ignored)
        ": this is a comment\ndata: {\"event\":\"after_comment\"}\n\n",
        # ID field (should be ignored)
        "id: 123\ndata: {\"event\":\"with_id\"}\n\n",
        # Done marker
        "data: [DONE]\n\n"
      ]

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        TestHelpers.sse_response(conn, sse_chunks)
      end)

      {:ok, stream} = Streaming.stream(streaming, endpoint_id, [])

      assert {:ok, %{"event" => "standard"}} = Streaming.next(stream)
      assert {:ok, %{"event" => "multiple"}} = Streaming.next(stream)
      assert {:ok, %{"event" => "with_type"}} = Streaming.next(stream)
      assert {:ok, %{"event" => "after_comment"}} = Streaming.next(stream)
      assert {:ok, %{"event" => "with_id"}} = Streaming.next(stream)
      assert {:ok, :done} = Streaming.next(stream)
    end

    test "handles chunked data across boundaries", %{
      bypass: bypass,
      config: _config,
      streaming: streaming
    } do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      # Simulate data split across chunk boundaries
      chunks = [
        "da",
        "ta: {\"ev",
        "ent\":\"sp",
        "lit\"}\n",
        "\n",
        "data: [DONE]\n\n"
      ]

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          # Small delay between chunks
          Process.sleep(10)
          conn
        end)
      end)

      {:ok, stream} = Streaming.stream(streaming, endpoint_id, [])

      assert {:ok, %{"event" => "split"}} = Streaming.next(stream)
      assert {:ok, :done} = Streaming.next(stream)
    end
  end

  describe "streaming with real model responses" do
    test "image generation progress", %{bypass: bypass, config: _config, streaming: streaming} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      progress_events = [
        %{"type" => "start", "data" => %{"model" => endpoint_id}},
        %{"type" => "progress", "data" => %{"percentage" => 0}},
        %{"type" => "progress", "data" => %{"percentage" => 25}},
        %{"type" => "progress", "data" => %{"percentage" => 50}},
        %{"type" => "progress", "data" => %{"percentage" => 75}},
        %{"type" => "progress", "data" => %{"percentage" => 100}},
        %{"type" => "output", "data" => Fixtures.image_generation_response()},
        %{"type" => "complete", "data" => %{"duration" => 2.5}}
      ]

      sse_chunks =
        Enum.map(progress_events, fn event ->
          "data: #{Jason.encode!(event)}\n\n"
        end) ++ ["data: [DONE]\n\n"]

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        TestHelpers.sse_response(conn, sse_chunks)
      end)

      {:ok, stream} = Streaming.stream(streaming, endpoint_id, [])

      # Collect all events until done
      events = collect_stream_events(stream, [])

      # Verify we got progress events
      progress_events =
        Enum.filter(events, fn event ->
          event["type"] == "progress"
        end)

      assert length(progress_events) > 0

      Streaming.close(stream)
    end
  end

  describe "error recovery" do
    test "handles server errors during streaming", %{
      bypass: bypass,
      config: _config,
      streaming: streaming
    } do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"error\":\"Internal error\"}\n\n")
        # Then server closes connection
        conn
      end)

      {:ok, stream} = Streaming.stream(streaming, endpoint_id, [])

      assert {:ok, %{"error" => "Internal error"}} = Streaming.next(stream)
      # Server closed after sending valid SSE data, so we get :done
      assert {:ok, :done} = Streaming.next(stream)
    end
  end

  # Helper function to collect all stream events
  defp collect_stream_events(stream, acc) do
    case Streaming.next(stream) do
      {:ok, :done} ->
        Enum.reverse(acc)

      {:ok, event} ->
        collect_stream_events(stream, [event | acc])

      {:error, _} ->
        Enum.reverse(acc)
    end
  end
end
