defmodule FalEx.AppConfigTest do
  use ExUnit.Case, async: false

  alias FalEx.Config

  describe "application configuration" do
    setup do
      # Store original config
      original_config = Application.get_all_env(:fal_ex)

      # Clear all config before each test
      for {key, _} <- Application.get_all_env(:fal_ex) do
        Application.delete_env(:fal_ex, key)
      end

      # Clear env vars too
      original_env = %{
        "FAL_KEY" => System.get_env("FAL_KEY"),
        "FAL_KEY_ID" => System.get_env("FAL_KEY_ID"),
        "FAL_KEY_SECRET" => System.get_env("FAL_KEY_SECRET")
      }

      System.delete_env("FAL_KEY")
      System.delete_env("FAL_KEY_ID")
      System.delete_env("FAL_KEY_SECRET")

      # Clean up after each test
      on_exit(fn ->
        # Clear all fal_ex config
        for {key, _} <- Application.get_all_env(:fal_ex) do
          Application.delete_env(:fal_ex, key)
        end

        # Restore original config
        for {key, value} <- original_config do
          Application.put_env(:fal_ex, key, value)
        end

        # Restore env vars
        for {key, value} <- original_env do
          if value do
            System.put_env(key, value)
          else
            System.delete_env(key)
          end
        end
      end)

      :ok
    end

    test "reads api_key from application config" do
      Application.put_env(:fal_ex, :api_key, "app_config_key")

      config = Config.new()
      assert Config.resolve_credentials(config) == "app_config_key"
    end

    test "reads api_key_id and api_key_secret from application config" do
      # Make sure no api_key is set
      Application.delete_env(:fal_ex, :api_key)
      Application.put_env(:fal_ex, :api_key_id, "app_id")
      Application.put_env(:fal_ex, :api_key_secret, "app_secret")

      config = Config.new()
      assert Config.resolve_credentials(config) == {"app_id", "app_secret"}
    end

    test "explicit options override application config" do
      Application.put_env(:fal_ex, :api_key, "app_config_key")
      Application.put_env(:fal_ex, :base_url, "https://app.config.url")

      config = Config.new(credentials: "explicit_key", base_url: "https://explicit.url")

      assert Config.resolve_credentials(config) == "explicit_key"
      assert config.base_url == "https://explicit.url"
    end

    test "reads other configuration options from app config" do
      Application.put_env(:fal_ex, :base_url, "https://custom.fal.ai")
      Application.put_env(:fal_ex, :proxy_url, "/api/proxy")

      config = Config.new()

      assert config.base_url == "https://custom.fal.ai"
      assert config.proxy_url == "/api/proxy"
    end

    test "environment variables take precedence over app config for credentials" do
      Application.put_env(:fal_ex, :api_key, "app_config_key")
      System.put_env("FAL_KEY", "env_var_key")

      config = Config.new()
      assert Config.resolve_credentials(config) == "env_var_key"

      System.delete_env("FAL_KEY")
    end

    test "works with no configuration set" do
      # Ensure no app config or env vars
      System.delete_env("FAL_KEY")
      System.delete_env("FAL_KEY_ID")
      System.delete_env("FAL_KEY_SECRET")

      config = Config.new()
      assert Config.resolve_credentials(config) == nil
      # default value
      assert config.base_url == "https://fal.run"
    end
  end

  describe "configuration in practice" do
    test "usage example with app config" do
      # This is how users would configure in their config.exs:
      # config :fal_ex,
      #   api_key: "your-api-key",
      #   base_url: "https://custom.fal.ai"

      # Ensure env vars are cleared
      System.delete_env("FAL_KEY")
      System.delete_env("FAL_KEY_ID")
      System.delete_env("FAL_KEY_SECRET")

      Application.put_env(:fal_ex, :api_key, "test-key-123")

      # Then they can just call FalEx functions without passing config
      config = Config.new()
      assert Config.resolve_credentials(config) == "test-key-123"
    end
  end
end
