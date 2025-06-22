defmodule FalEx.ConfigTest do
  use FalEx.TestCase
  doctest FalEx.Config

  alias FalEx.Config

  describe "new/1" do
    test "creates config with default values" do
      config = Config.new()

      assert config.base_url == "https://fal.run"
      assert config.credentials == nil
      assert config.proxy_url == nil
    end

    test "accepts API key as string" do
      config = Config.new(credentials: "test-key")

      assert config.credentials == "test-key"
    end

    test "accepts API key as tuple" do
      config = Config.new(credentials: {"key-id", "key-secret"})

      assert config.credentials == {"key-id", "key-secret"}
    end

    test "accepts resolver function" do
      resolver = fn -> "resolved-key" end
      config = Config.new(credentials: resolver)

      assert is_function(config.credentials, 0)
    end

    test "resolves credentials from environment" do
      System.put_env("FAL_KEY", "env-key")

      config = Config.new()

      assert Config.resolve_credentials(config) == "env-key"
    end

    test "resolves key ID and secret from environment" do
      System.put_env("FAL_KEY_ID", "env-id")
      System.put_env("FAL_KEY_SECRET", "env-secret")

      config = Config.new()

      assert Config.resolve_credentials(config) == {"env-id", "env-secret"}
    end
  end

  describe "resolve_credentials/1" do
    test "returns nil when no credentials" do
      config = Config.new()
      assert Config.resolve_credentials(config) == nil
    end

    test "returns string credentials directly" do
      config = Config.new(credentials: "direct-key")
      assert Config.resolve_credentials(config) == "direct-key"
    end

    test "returns tuple credentials directly" do
      config = Config.new(credentials: {"id", "secret"})
      assert Config.resolve_credentials(config) == {"id", "secret"}
    end

    test "calls resolver function" do
      config = Config.new(credentials: fn -> "resolved" end)
      assert Config.resolve_credentials(config) == "resolved"
    end
  end

  describe "using_proxy?/1" do
    test "returns false when no proxy URL" do
      config = Config.new()
      refute Config.using_proxy?(config)
    end

    test "returns true when proxy URL is set" do
      config = Config.new(proxy_url: "/api/proxy")
      assert Config.using_proxy?(config)
    end
  end

  describe "get_base_url/1" do
    test "returns base URL when no proxy" do
      config = Config.new(base_url: "https://custom.fal.run")
      assert Config.get_base_url(config) == "https://custom.fal.run"
    end

    test "returns proxy URL when proxy is set" do
      config =
        Config.new(
          base_url: "https://fal.run",
          proxy_url: "/api/proxy"
        )

      assert Config.get_base_url(config) == "/api/proxy"
    end
  end
end
