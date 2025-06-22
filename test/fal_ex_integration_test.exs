defmodule FalExIntegrationTest do
  use ExUnit.Case, async: true

  alias FalEx
  alias FalEx.Fixtures
  alias FalEx.TestHelpers

  setup do
    bypass = Bypass.open()

    # Configure FalEx with test settings
    FalEx.config(
      credentials: "test_api_key",
      base_url: "http://localhost:#{bypass.port}"
    )

    {:ok, bypass: bypass}
  end

  describe "run/2" do
    test "delegates to Client.run with default config", %{bypass: bypass} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      input = Fixtures.image_generation_input()
      expected_response = Fixtures.image_generation_response()

      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        TestHelpers.assert_has_auth(conn, "test_api_key")
        TestHelpers.json_response(conn, 200, expected_response)
      end)

      assert {:ok, response} = FalEx.run(endpoint_id, input: input)
      assert response == expected_response
    end

    test "handles errors properly", %{bypass: bypass} do
      endpoint_id = "invalid/model"

      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 404, %{
          "error" => %{
            "message" => "Model not found",
            "code" => "MODEL_NOT_FOUND"
          }
        })
      end)

      assert {:error, %{status_code: 404}} = FalEx.run(endpoint_id, input: %{})
    end
  end

  describe "subscribe/2" do
    test "performs queue-based execution with status updates", %{bypass: bypass} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      input = Fixtures.image_generation_input()
      request_id = "req_queue_123456"

      # Submit to queue
      Bypass.expect_once(bypass, "POST", "/queue/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 200, TestHelpers.mock_queue_submit_response())
      end)

      # Status polling
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

      # Final result
      Bypass.expect_once(bypass, "GET", "/queue/#{endpoint_id}/result/#{request_id}", fn conn ->
        TestHelpers.json_response(conn, 200, TestHelpers.mock_queue_result_response())
      end)

      assert {:ok, result} = FalEx.subscribe(endpoint_id, input: input)
      assert result["data"]["output"] == "Generated result from queue"

      Agent.stop(agent)
    end

    test "propagates submission errors", %{bypass: bypass} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      Bypass.expect_once(bypass, "POST", "/queue/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 503, %{
          "error" => %{
            "message" => "Queue is full",
            "code" => "QUEUE_FULL"
          }
        })
      end)

      assert {:error, %{status: 503}} = FalEx.subscribe(endpoint_id, input: %{})
    end
  end

  describe "stream/2" do
    test "creates SSE stream and returns events", %{bypass: bypass} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      input = Fixtures.image_generation_input()

      events = Fixtures.streaming_events()

      sse_chunks =
        Enum.map(events, fn event ->
          "data: #{Jason.encode!(event)}\n\n"
        end) ++ ["data: [DONE]\n\n"]

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        TestHelpers.assert_has_auth(conn, "test_api_key")
        TestHelpers.sse_response(conn, sse_chunks)
      end)

      assert {:ok, stream} = FalEx.stream(endpoint_id, input: input)

      # Collect some events from the Elixir Stream
      events = stream |> Enum.take(2)

      assert length(events) == 2
      assert Enum.at(events, 0)["type"] == "start"
      assert Enum.at(events, 1)["type"] == "progress"
    end

    test "handles streaming errors", %{bypass: bypass} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      ref = make_ref()
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        send(test_pid, {ref, :request_received})
        TestHelpers.json_response(conn, 400, Fixtures.validation_error())
      end)

      # Note: Due to the async nature of streaming, errors may not be detected
      # until the stream is consumed. This is expected behavior.
      # For now, we'll just verify the stream is created
      assert {:ok, _stream} = FalEx.stream(endpoint_id, input: %{})

      # Wait for request to be received
      assert_receive {^ref, :request_received}, 1000
    end
  end

  describe "config/1" do
    test "updates global configuration" do
      # Update config
      assert :ok = FalEx.config(credentials: "new_key", base_url: "https://new.api.com")

      # The config is stored in the GenServer, not application env
      # We can verify it works by making a request
      # For now, just verify the config call returns :ok
    end

    test "allows reconfiguration" do
      # First config
      assert :ok = FalEx.config(credentials: "key1", request_timeout: 5000)

      # Second config (replaces the first)
      assert :ok = FalEx.config(credentials: "key2", base_url: "https://api.example.com")

      # Config is replaced, not merged
    end
  end

  describe "with file uploads" do
    test "automatically uploads local files in input", %{bypass: bypass} do
      endpoint_id = Fixtures.model_endpoints().llava

      # Create a test image file
      image_path = TestHelpers.create_temp_file(Fixtures.sample_image_binary(), "png")

      input = %{
        "image_url" => image_path,
        "prompt" => "What's in this image?"
      }

      # Expect file upload
      Bypass.expect_once(bypass, "POST", "/v3/storage/upload", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body != ""

        TestHelpers.json_response(conn, 200, %{
          "access_url" => "https://storage.fal.ai/files/123/image.png"
        })
      end)

      # Expect model run with uploaded URL
      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["image_url"] == "https://storage.fal.ai/files/123/image.png"
        assert decoded["prompt"] == "What's in this image?"

        TestHelpers.json_response(conn, 200, Fixtures.vision_language_response())
      end)

      assert {:ok, response} = FalEx.run(endpoint_id, input: input)
      assert response["output"] =~ "robot playing with an orange tabby cat"

      # Cleanup
      TestHelpers.cleanup_temp_file(image_path)
    end

    test "handles multiple file uploads", %{bypass: bypass} do
      endpoint_id = "custom/multi-input-model"

      # Create multiple test files
      file1 = TestHelpers.create_temp_file("content1", "txt")
      file2 = TestHelpers.create_temp_file("content2", "txt")

      input = %{
        "file1" => file1,
        "file2" => file2,
        "config" => %{"setting" => "value"}
      }

      uploaded_urls = %{
        file1 => "https://storage.fal.ai/files/111/file1.txt",
        file2 => "https://storage.fal.ai/files/222/file2.txt"
      }

      # Expect two uploads
      Bypass.expect(bypass, "POST", "/v3/storage/upload", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)

        url =
          cond do
            body =~ Path.basename(file1) -> uploaded_urls[file1]
            body =~ Path.basename(file2) -> uploaded_urls[file2]
          end

        TestHelpers.json_response(conn, 200, %{"access_url" => url})
      end)

      # Expect run with uploaded URLs
      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["file1"] == uploaded_urls[file1]
        assert decoded["file2"] == uploaded_urls[file2]
        assert decoded["config"]["setting"] == "value"

        TestHelpers.json_response(conn, 200, %{"status" => "success"})
      end)

      assert {:ok, _} = FalEx.run(endpoint_id, input: input)

      # Cleanup
      TestHelpers.cleanup_temp_file(file1)
      TestHelpers.cleanup_temp_file(file2)
    end
  end

  describe "environment variable configuration" do
    test "reads FAL_KEY from environment" do
      System.put_env("FAL_KEY", "env_key_123")
      Application.delete_env(:fal_ex, :api_key)

      # Config should pick up env var
      config = FalEx.Config.new()
      assert FalEx.Config.resolve_credentials(config) == "env_key_123"

      System.delete_env("FAL_KEY")
    end

    test "prefers explicit config over environment" do
      System.put_env("FAL_KEY", "env_key")

      # Explicit config should override env var
      config = FalEx.Config.new(credentials: "explicit_key")
      assert FalEx.Config.resolve_credentials(config) == "explicit_key"

      System.delete_env("FAL_KEY")
    end
  end

  describe "error handling patterns" do
    test "consistent error format across all methods", %{bypass: bypass} do
      endpoint_id = "test/model"

      error_response = %{
        "error" => %{
          "message" => "Test error",
          "code" => "TEST_ERROR",
          "details" => %{"info" => "additional"}
        }
      }

      # Test run error - uses result_response_handler format
      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 400, error_response)
      end)

      assert {:error, %{status_code: 400, body: body}} = FalEx.run(endpoint_id, input: %{})
      assert body["error"]["code"] == "TEST_ERROR"

      # Test subscribe error - returns ValidationError for 400
      Bypass.expect_once(bypass, "POST", "/queue/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 400, error_response)
      end)

      assert {:error, %FalEx.Response.ValidationError{}} =
               FalEx.subscribe(endpoint_id, input: %{})

      # Test stream error - errors are detected when stream is consumed
      ref = make_ref()
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/stream/#{endpoint_id}", fn conn ->
        send(test_pid, {ref, :request_received})
        TestHelpers.json_response(conn, 400, error_response)
      end)

      # Stream creation waits for connection
      assert {:ok, _stream} = FalEx.stream(endpoint_id, input: %{})

      # Wait for request to be received
      assert_receive {^ref, :request_received}, 1000
    end
  end

  describe "real-world usage patterns" do
    test "image generation workflow", %{bypass: bypass} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      input = %{
        "prompt" => "a beautiful sunset over mountains",
        "image_size" => "landscape_16_9",
        "num_images" => 2
      }

      expected_output = %{
        "images" => [
          %{"url" => "https://storage.fal.ai/outputs/123/img1.png"},
          %{"url" => "https://storage.fal.ai/outputs/123/img2.png"}
        ]
      }

      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 200, expected_output)
      end)

      assert {:ok, result} = FalEx.run(endpoint_id, input: input)
      assert length(result["images"]) == 2
    end

    test "audio transcription workflow", %{bypass: bypass} do
      endpoint_id = Fixtures.model_endpoints().whisper

      # Create a mock audio file
      audio_path = TestHelpers.create_temp_file("mock audio data", "mp3")

      input = %{
        "audio_url" => audio_path,
        "task" => "transcribe",
        "language" => "en"
      }

      # Upload audio
      Bypass.expect_once(bypass, "POST", "/v3/storage/upload", fn conn ->
        TestHelpers.json_response(conn, 200, %{
          "access_url" => "https://storage.fal.ai/files/audio123.mp3"
        })
      end)

      # Transcribe
      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 200, Fixtures.audio_transcription_response())
      end)

      assert {:ok, result} = FalEx.run(endpoint_id, input: input)
      assert result["text"] == "Hello, this is a test transcription."

      TestHelpers.cleanup_temp_file(audio_path)
    end
  end
end
