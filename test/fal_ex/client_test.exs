defmodule FalEx.ClientTest do
  use ExUnit.Case, async: false

  alias FalEx.Client
  alias FalEx.Config
  alias FalEx.Fixtures
  alias FalEx.TestHelpers

  setup do
    bypass = Bypass.open()

    config =
      Config.new(
        credentials: "test_api_key",
        base_url: "http://localhost:#{bypass.port}"
      )

    client = Client.create(config)

    {:ok, bypass: bypass, config: config, client: client}
  end

  describe "run/3" do
    test "successfully runs a model with valid input", %{bypass: bypass, client: client} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      input = Fixtures.image_generation_input()
      expected_response = Fixtures.image_generation_response()

      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Key test_api_key"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == input

        TestHelpers.json_response(conn, 200, expected_response)
      end)

      assert {:ok, response} = Client.run(client, endpoint_id, input: input)
      assert response == expected_response
    end

    test "handles model not found error", %{bypass: bypass, client: client} do
      endpoint_id = "non-existent/model"

      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 404, %{
          "error" => %{
            "message" => "Model not found",
            "code" => "MODEL_NOT_FOUND"
          }
        })
      end)

      assert {:error, %{status_code: 404, body: %{"error" => %{"code" => "MODEL_NOT_FOUND"}}}} =
               Client.run(client, endpoint_id, input: %{})
    end

    test "handles validation errors", %{bypass: bypass, client: client} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      invalid_input = %{"invalid" => "input"}

      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 400, Fixtures.validation_error())
      end)

      assert {:error, %{status_code: 400, body: %{"error" => %{"code" => "VALIDATION_ERROR"}}}} =
               Client.run(client, endpoint_id, input: invalid_input)
    end

    test "handles authentication errors", %{bypass: bypass} do
      config =
        Config.new(
          credentials: "invalid",
          base_url: "http://localhost:#{bypass.port}"
        )

      client = Client.create(config)
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 401, Fixtures.auth_error())
      end)

      assert {:error, %{status_code: 401, body: %{"error" => %{"code" => "UNAUTHORIZED"}}}} =
               Client.run(client, endpoint_id, input: %{})
    end

    test "handles rate limiting", %{bypass: bypass, client: client} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 429, Fixtures.rate_limit_error())
      end)

      assert {:error, %{status_code: 429, body: %{"error" => error}}} =
               Client.run(client, endpoint_id, input: %{})

      assert error["code"] == "RATE_LIMIT_EXCEEDED"
      assert error["details"]["retry_after"] == 60
    end

    test "handles server errors", %{bypass: bypass, client: client} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 500, TestHelpers.mock_error_response())
      end)

      assert {:error, %{status_code: 500}} = Client.run(client, endpoint_id, input: %{})
    end

    test "handles network errors", %{bypass: _bypass} do
      # Use a config with an invalid URL
      config =
        Config.new(
          credentials: "test_api_key",
          base_url: "http://localhost:99999"
        )

      client = Client.create(config)

      # Network errors can result in either timeout or connection refused
      result = Client.run(client, "test/model", input: %{}, timeout: 1000)
      assert match?({:error, error} when error in [:timeout, :econnrefused], result)
    end

    test "respects custom timeout", %{bypass: bypass, client: client} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        # Delay longer than timeout
        Process.sleep(200)
        TestHelpers.json_response(conn, 200, %{})
      end)

      assert {:error, :timeout} =
               Client.run(client, endpoint_id, input: %{}, timeout: 100)
    end

    test "properly formats endpoint URL", %{bypass: bypass, client: client} do
      # Test with various endpoint formats
      test_cases = [
        {"fal-ai/fast-sdxl", "/v1/run/fal-ai/fast-sdxl"},
        {"custom/model-v2", "/v1/run/custom/model-v2"},
        {"110602490-lora", "/v1/run/110602490-lora"}
      ]

      Enum.each(test_cases, fn {endpoint_id, expected_path} ->
        Bypass.expect_once(bypass, "POST", expected_path, fn conn ->
          TestHelpers.json_response(conn, 200, %{"result" => "ok"})
        end)

        assert {:ok, _} = Client.run(client, endpoint_id, input: %{})
      end)
    end

    test "handles different response content types", %{bypass: bypass, client: client} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      # Test JSON response with different content-type headers
      content_types = [
        "application/json",
        "application/json; charset=utf-8",
        "application/json;charset=UTF-8"
      ]

      Enum.each(content_types, fn content_type ->
        Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type(content_type)
          |> Plug.Conn.resp(200, Jason.encode!(%{"result" => "ok"}))
        end)

        assert {:ok, %{"result" => "ok"}} = Client.run(client, endpoint_id, input: %{})
      end)
    end
  end

  describe "input handling" do
    test "accepts various input types", %{bypass: bypass, client: client} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      test_inputs = [
        # Empty map
        %{},
        %{"string" => "value", "number" => 42, "boolean" => true, "null" => nil},
        %{"nested" => %{"key" => "value"}},
        %{"array" => [1, 2, 3]},
        %{"unicode" => "emoji 🎨 test"},
        %{"special_chars" => "!@#$%^&*()"}
      ]

      Enum.each(test_inputs, fn input ->
        Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body) == input
          TestHelpers.json_response(conn, 200, %{"echo" => input})
        end)

        assert {:ok, %{"echo" => ^input}} = Client.run(client, endpoint_id, input: input)
      end)
    end

    test "handles large inputs", %{bypass: bypass, client: client} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl
      # Create a large input
      large_input = %{
        "data" =>
          Enum.map(1..1000, fn i ->
            %{"index" => i, "value" => "test_#{i}"}
          end)
      }

      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert length(decoded["data"]) == 1000
        TestHelpers.json_response(conn, 200, %{"received" => true})
      end)

      assert {:ok, %{"received" => true}} = Client.run(client, endpoint_id, input: large_input)
    end
  end

  describe "path encoding" do
    test "properly handles endpoint IDs", %{bypass: bypass, client: client} do
      # Test various valid endpoint ID formats
      endpoints = [
        "fal-ai/fast-sdxl",
        "custom/model-v2",
        "110602490-lora",
        "simple-model"
      ]

      Enum.each(endpoints, fn endpoint_id ->
        Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
          TestHelpers.json_response(conn, 200, %{"result" => "ok"})
        end)

        result = Client.run(client, endpoint_id, input: %{})
        assert {:ok, _} = result
      end)
    end
  end

  describe "response handling" do
    test "preserves all response fields", %{bypass: bypass, client: client} do
      endpoint_id = Fixtures.model_endpoints().fast_sdxl

      complex_response = %{
        "data" => %{
          "nested" => %{
            "deeply" => %{
              "nested" => "value"
            }
          },
          "array" => [1, 2, 3],
          "null_value" => nil,
          "boolean" => true
        },
        "metadata" => %{
          "request_id" => "req_123",
          "timestamp" => "2024-01-01T12:00:00Z"
        }
      }

      Bypass.expect_once(bypass, "POST", "/v1/run/#{endpoint_id}", fn conn ->
        TestHelpers.json_response(conn, 200, complex_response)
      end)

      assert {:ok, response} = Client.run(client, endpoint_id, input: %{})
      assert response == complex_response
    end
  end
end
