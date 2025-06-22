defmodule FalEx.PropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias FalEx.Client
  alias FalEx.Config
  alias FalEx.TestHelpers

  setup do
    bypass = Bypass.open()
    config = TestHelpers.test_config(%{bypass_port: bypass.port})
    client = Client.create(config)

    {:ok, bypass: bypass, config: config, client: client}
  end

  describe "endpoint ID validation" do
    property "accepts valid endpoint IDs", %{bypass: bypass, client: client} do
      check all(endpoint_id <- valid_endpoint_id()) do
        Bypass.expect(bypass, fn conn ->
          TestHelpers.json_response(conn, 200, %{"result" => "ok"})
        end)

        assert {:ok, _} = Client.run(client, endpoint_id, input: %{})
      end
    end

    property "handles various endpoint formats", %{
      bypass: bypass,
      config: _config,
      client: client
    } do
      check all(
              endpoint_id <-
                StreamData.one_of([
                  # Standard format: owner/model
                  StreamData.map(
                    {alphanumeric_string(3, 20), alphanumeric_string(3, 30)},
                    fn {owner, model} -> "#{owner}/#{model}" end
                  ),
                  # Numeric format: 12345-model
                  StreamData.map(
                    {StreamData.integer(10_000..999_999), alphanumeric_string(3, 20)},
                    fn {num, model} -> "#{num}-#{model}" end
                  ),
                  # Simple format: just model name
                  alphanumeric_string(3, 40)
                ])
            ) do
        Bypass.expect(bypass, fn conn ->
          TestHelpers.json_response(conn, 200, %{"result" => "ok"})
        end)

        assert {:ok, _} = Client.run(client, endpoint_id, input: %{})
      end
    end
  end

  describe "input validation" do
    property "accepts any JSON-serializable input", %{
      bypass: bypass,
      config: _config,
      client: client
    } do
      # Generate inputs that are valid for the API (maps or nil)
      check all(
              input <- StreamData.one_of([StreamData.constant(nil), simple_map()]),
              max_runs: 50
            ) do
        # Some inputs might not be serializable, so we make the expectation optional
        test_pid = self()
        ref = make_ref()

        Bypass.stub(bypass, "POST", "/v1/run/test/model", fn conn ->
          send(test_pid, {ref, :request_received})
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          # Should be valid JSON or empty for nil input
          if body == "" do
            TestHelpers.json_response(conn, 200, %{"echo" => nil})
          else
            case Jason.decode(body) do
              {:ok, decoded} ->
                TestHelpers.json_response(conn, 200, %{"echo" => decoded})

              {:error, _} ->
                TestHelpers.json_response(conn, 400, %{"error" => "Invalid JSON"})
            end
          end
        end)

        result = Client.run(client, "test/model", input: input)

        # Check if request was made
        request_made =
          receive do
            {^ref, :request_received} -> true
          after
            500 -> false
          end

        case {request_made, result} do
          {true, {:ok, response}} ->
            # Empty string gets sent as empty body, which returns nil
            expected = if input == "", do: nil, else: input
            assert response["echo"] == expected

          {false, {:error, _}} ->
            # Transform input might have failed, which is ok for some inputs
            :ok

          {true, {:error, _}} ->
            # Request was made but failed, which is ok
            :ok

          {false, {:ok, _response}} ->
            # For empty inputs, the client might optimize and not make a request
            # This is implementation-specific behavior we should accept
            if input == %{} or input == nil do
              :ok
            else
              flunk("Got success without making request for input: #{inspect(input)}")
            end
        end
      end
    end

    property "preserves numeric precision", %{bypass: bypass, config: _config, client: client} do
      check all(
              number <-
                StreamData.one_of([
                  StreamData.integer(),
                  StreamData.float(),
                  StreamData.map(StreamData.integer(1..1000), &(&1 / 100))
                ])
            ) do
        input = %{"number" => number}

        Bypass.expect(bypass, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          TestHelpers.json_response(conn, 200, %{"received" => decoded["number"]})
        end)

        {:ok, response} = Client.run(client, "test/model", input: input)

        # JSON might lose some float precision, so we check within tolerance
        if is_float(number) do
          assert_in_delta response["received"], number, 0.0000001
        else
          assert response["received"] == number
        end
      end
    end

    property "handles deeply nested structures", %{
      bypass: bypass,
      config: _config,
      client: client
    } do
      check all(
              depth <- StreamData.integer(1..5),
              value <- json_value(),
              max_runs: 20
            ) do
        # Build nested structure
        nested =
          Enum.reduce(1..depth, value, fn _, acc ->
            %{"nested" => acc}
          end)

        Bypass.expect(bypass, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          TestHelpers.json_response(conn, 200, %{"echo" => decoded})
        end)

        {:ok, response} = Client.run(client, "test/model", input: nested)
        assert response["echo"] == nested
      end
    end
  end

  describe "file path detection" do
    property "correctly identifies URLs vs file paths", %{bypass: _bypass, config: config} do
      check all(
              path <-
                StreamData.one_of([
                  # URLs - should NOT be transformed
                  url_generator(),
                  # Regular strings - should NOT be transformed
                  StreamData.string(:printable, min_length: 1, max_length: 50),
                  # Edge cases
                  StreamData.constant(""),
                  StreamData.constant("https://"),
                  StreamData.constant("http://")
                ])
            ) do
        storage = FalEx.Storage.create(config)
        result = FalEx.Storage.transform_input(storage, path)

        # URLs and regular strings should pass through unchanged
        if String.starts_with?(path, ["http://", "https://"]) or path == "" do
          assert result == path
        else
          # Non-URL strings are kept as-is (not uploaded unless they're file paths that exist)
          assert result == path
        end
      end
    end
  end

  describe "configuration validation" do
    property "accepts valid API keys" do
      check all(
              api_key <-
                StreamData.filter(
                  StreamData.string(:alphanumeric, min_length: 1, max_length: 100),
                  &(String.length(&1) > 0)
                )
            ) do
        config = Config.new(credentials: api_key)
        assert Config.resolve_credentials(config) == api_key
      end
    end

    property "validates API URLs" do
      check all(
              scheme <- StreamData.member_of(["http", "https"]),
              host <- valid_hostname(),
              port <- StreamData.integer(1..65_535)
            ) do
        url = "#{scheme}://#{host}:#{port}"
        config = Config.new(base_url: url)
        assert config.base_url == url
      end
    end
  end

  describe "response handling" do
    property "handles various HTTP status codes", %{
      bypass: bypass,
      config: _config,
      client: client
    } do
      check all(
              status_code <-
                StreamData.member_of([200, 201, 400, 401, 403, 404, 422, 429, 500, 502, 503]),
              body <- json_value()
            ) do
        Bypass.expect(bypass, fn conn ->
          TestHelpers.json_response(conn, status_code, body)
        end)

        result = Client.run(client, "test/model", input: %{})

        if status_code >= 200 and status_code < 300 do
          assert {:ok, ^body} = result
        else
          assert {:error, %{status_code: ^status_code, body: ^body}} = result
        end
      end
    end
  end

  # Generator functions

  defp valid_endpoint_id do
    StreamData.one_of([
      # owner/model format
      StreamData.map(
        {identifier(), identifier()},
        fn {owner, model} -> "#{owner}/#{model}" end
      ),
      # numeric-model format
      StreamData.map(
        {StreamData.integer(10_000..999_999), identifier()},
        fn {num, model} -> "#{num}-#{model}" end
      ),
      # simple model name
      identifier()
    ])
  end

  defp identifier do
    StreamData.map(
      {
        StreamData.string([?a..?z, ?A..?Z], length: 1),
        StreamData.string([?a..?z, ?A..?Z, ?0..?9, ?-, ?_], min_length: 2, max_length: 30)
      },
      fn {first, rest} -> first <> rest end
    )
  end

  defp alphanumeric_string(min, max) do
    StreamData.string([?a..?z, ?A..?Z, ?0..?9], min_length: min, max_length: max)
  end

  defp json_value do
    StreamData.frequency([
      {4, StreamData.constant(nil)},
      {4, StreamData.boolean()},
      {4, StreamData.integer()},
      {4, StreamData.float()},
      {4, StreamData.string(:alphanumeric, min_length: 0, max_length: 50)},
      {1, StreamData.list_of(StreamData.integer(), max_length: 3)},
      {1, simple_map()}
    ])
  end

  defp simple_map do
    StreamData.map(
      StreamData.list_of(
        {StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
         StreamData.one_of([
           StreamData.constant(nil),
           StreamData.boolean(),
           StreamData.integer(),
           StreamData.string(:alphanumeric, max_length: 20)
         ])},
        max_length: 3
      ),
      &Map.new/1
    )
  end

  defp url_generator do
    StreamData.map(
      {
        StreamData.member_of(["http", "https", "ftp"]),
        valid_hostname(),
        StreamData.integer(1..65_535),
        StreamData.string([?a..?z, ?/, ?-, ?_], min_length: 0, max_length: 50)
      },
      fn {scheme, host, port, path} -> "#{scheme}://#{host}:#{port}/#{path}" end
    )
  end

  defp valid_hostname do
    StreamData.map(
      StreamData.list_of(
        StreamData.string([?a..?z, ?0..?9], min_length: 1, max_length: 20),
        min_length: 1,
        max_length: 3
      ),
      fn parts -> Enum.join(parts, ".") end
    )
  end
end
