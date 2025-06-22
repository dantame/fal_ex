defmodule FalExTest do
  use ExUnit.Case
  doctest FalEx

  describe "module exists" do
    test "FalEx module is available" do
      assert Code.ensure_loaded?(FalEx)
    end

    test "FalEx can be started" do
      # The FalEx GenServer might not be started in test environment
      # Let's just verify we can start it
      case Process.whereis(FalEx) do
        nil ->
          # Try to start it
          assert {:ok, _pid} = FalEx.start_link()

        pid ->
          # Already running
          assert is_pid(pid)
      end
    end
  end
end
