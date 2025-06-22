# Ensure test support files are compiled
Code.compile_file("test/support/test_helpers.ex")
Code.compile_file("test/support/fixtures.ex")
Code.compile_file("test/support/case_template.ex")

# Clear environment variables that might interfere with tests
System.delete_env("FAL_KEY")
System.delete_env("FAL_KEY_ID")
System.delete_env("FAL_KEY_SECRET")

# Clear any application config
for {key, _} <- Application.get_all_env(:fal_ex) do
  Application.delete_env(:fal_ex, key)
end

ExUnit.start()
