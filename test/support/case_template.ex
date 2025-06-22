defmodule FalEx.TestCase do
  @moduledoc """
  Base test case module that ensures proper environment isolation.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import FalEx.TestHelpers
      import FalEx.Fixtures
    end
  end

  setup _tags do
    # Store current environment state
    env_backup = %{
      "FAL_KEY" => System.get_env("FAL_KEY"),
      "FAL_KEY_ID" => System.get_env("FAL_KEY_ID"),
      "FAL_KEY_SECRET" => System.get_env("FAL_KEY_SECRET")
    }

    # Store current application config
    app_config_backup = Application.get_all_env(:fal_ex)

    # Clear environment variables
    System.delete_env("FAL_KEY")
    System.delete_env("FAL_KEY_ID")
    System.delete_env("FAL_KEY_SECRET")

    # Clear application config
    for {key, _} <- Application.get_all_env(:fal_ex) do
      Application.delete_env(:fal_ex, key)
    end

    # Ensure cleanup after test
    on_exit(fn ->
      # Restore environment variables
      for {key, value} <- env_backup do
        if value do
          System.put_env(key, value)
        else
          System.delete_env(key)
        end
      end

      # Clear any config set during test
      for {key, _} <- Application.get_all_env(:fal_ex) do
        Application.delete_env(:fal_ex, key)
      end

      # Restore original application config
      for {key, value} <- app_config_backup do
        Application.put_env(:fal_ex, key, value)
      end
    end)

    :ok
  end
end
