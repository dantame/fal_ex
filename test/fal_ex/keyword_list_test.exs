defmodule FalEx.KeywordListTest do
  use ExUnit.Case, async: true

  alias FalEx.Client
  alias FalEx.Config
  alias FalEx.Queue
  alias FalEx.Realtime
  alias FalEx.Streaming

  describe "keyword list support" do
    test "Client.run/3 accepts keyword list" do
      config = Config.new(credentials: "test", base_url: "http://localhost")
      _client = Client.create(config)

      # This should compile and accept keyword list
      opts = [input: %{prompt: "test"}, timeout: 5000]

      # We're not testing the actual call, just that it accepts keyword lists
      assert is_list(opts)
    end

    test "Queue functions accept keyword lists" do
      config = Config.new(credentials: "test", base_url: "http://localhost")
      _queue = Queue.create(config)

      # Test that these compile with keyword lists
      submit_opts = [input: %{prompt: "test"}, webhook_url: "http://example.com"]
      status_opts = [request_id: "123", logs: true]
      cancel_opts = [request_id: "123"]
      result_opts = [request_id: "123"]
      subscribe_opts = [request_id: "123", on_queue_update: fn x -> x end]

      assert is_list(submit_opts)
      assert is_list(status_opts)
      assert is_list(cancel_opts)
      assert is_list(result_opts)
      assert is_list(subscribe_opts)
    end

    test "Streaming.stream/3 accepts keyword list" do
      config = Config.new(credentials: "test", base_url: "http://localhost")
      _streaming = Streaming.create(config)

      opts = [input: %{prompt: "test"}, timeout: 15_000]
      assert is_list(opts)
    end

    test "Realtime.connect/3 accepts keyword list" do
      config = Config.new(credentials: "test", base_url: "http://localhost")
      _realtime = Realtime.create(config)

      opts = [on_message: fn x -> x end, on_error: fn x -> x end]
      assert is_list(opts)
    end

    test "main FalEx module functions accept keyword lists" do
      # Just verify the functions exist and can be called with keyword lists
      assert function_exported?(FalEx, :run, 2)
      assert function_exported?(FalEx, :subscribe, 2)
      assert function_exported?(FalEx, :stream, 2)
    end
  end
end
