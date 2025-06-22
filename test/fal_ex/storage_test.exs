defmodule FalEx.StorageTest do
  use ExUnit.Case, async: true

  alias FalEx.Fixtures
  alias FalEx.Storage
  alias FalEx.TestHelpers

  setup do
    bypass = Bypass.open()
    config = TestHelpers.test_config(%{bypass_port: bypass.port})
    storage = Storage.create(config)

    {:ok, bypass: bypass, config: config, storage: storage}
  end

  describe "upload/3 with file path" do
    test "successfully uploads a file", %{bypass: bypass, storage: storage} do
      # Create a temporary test file
      content = Fixtures.sample_text_content()
      file_path = TestHelpers.create_temp_file(content, "txt")

      expected_response = %{"access_url" => "https://storage.fal.ai/files/abc123/file.txt"}

      Bypass.expect_once(bypass, "POST", "/v3/storage/upload", fn conn ->
        # Verify auth header exists
        assert Plug.Conn.get_req_header(conn, "authorization") != []

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        # Storage uses form data encoding
        assert body != ""

        TestHelpers.json_response(conn, 200, expected_response)
      end)

      assert {:ok, url} = Storage.upload(storage, file_path)
      assert url == "https://storage.fal.ai/files/abc123/file.txt"

      # Cleanup
      TestHelpers.cleanup_temp_file(file_path)
    end

    test "handles non-existent file", %{storage: storage} do
      non_existent_path = "/tmp/non_existent_file_#{:rand.uniform(1_000_000)}.txt"

      # Ensure the file doesn't exist
      refute File.exists?(non_existent_path)

      assert {:error, :enoent} = Storage.upload(storage, non_existent_path)
    end

    test "preserves original filename", %{bypass: bypass, storage: storage} do
      content = "test content"
      filename = "special_file_name.txt"
      file_path = Path.join(System.tmp_dir!(), filename)
      File.write!(file_path, content)

      Bypass.expect_once(bypass, "POST", "/v3/storage/upload", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        # Check filename is included
        assert body =~ filename

        TestHelpers.json_response(conn, 200, %{
          "access_url" => "https://storage.fal.ai/files/abc123/#{filename}"
        })
      end)

      assert {:ok, url} = Storage.upload(storage, file_path)
      assert url =~ filename

      File.rm(file_path)
    end

    test "handles various file types", %{bypass: bypass, storage: storage} do
      test_files = [
        {"test.txt", "text/plain", "Hello world"},
        {"test.json", "application/json", ~s({"key": "value"})},
        {"test.png", "image/png", Fixtures.sample_image_binary()}
      ]

      Enum.each(test_files, fn {filename, _content_type, content} ->
        file_path = Path.join(System.tmp_dir!(), filename)

        # Write content
        File.write!(file_path, content)

        Bypass.expect_once(bypass, "POST", "/v3/storage/upload", fn conn ->
          TestHelpers.json_response(conn, 200, %{
            "access_url" => "https://storage.fal.ai/files/123/#{filename}"
          })
        end)

        assert {:ok, url} = Storage.upload(storage, file_path)
        assert url =~ filename

        File.rm(file_path)
      end)
    end
  end

  describe "upload/3 with binary data" do
    test "successfully uploads binary data", %{bypass: bypass, storage: storage} do
      binary_data = Fixtures.sample_image_binary()

      Bypass.expect_once(bypass, "POST", "/v3/storage/upload", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        # Binary data should be in the form body
        assert byte_size(body) > 0

        TestHelpers.json_response(conn, 200, %{
          "access_url" => "https://storage.fal.ai/files/abc123/file"
        })
      end)

      assert {:ok, url} = Storage.upload(storage, binary_data)
      assert url =~ "https://storage.fal.ai"
    end

    @tag :skip
    test "handles large binary uploads", %{bypass: bypass, storage: storage} do
      # Skip this test as it requires too much memory
      # Create a 100MB binary (above the 90MB multipart threshold)
      large_binary = :crypto.strong_rand_bytes(100 * 1024 * 1024)

      # Expect multipart initiation
      Bypass.expect_once(bypass, "POST", "/v3/storage/upload/initiate", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["file_size"] == byte_size(large_binary)

        TestHelpers.json_response(conn, 200, %{
          "upload_id" => "multipart_123",
          "parts" => [
            %{"part_number" => 1, "upload_url" => "http://localhost:#{bypass.port}/upload/part1"}
          ]
        })
      end)

      # Mock the part upload
      Bypass.expect_once(bypass, "PUT", "/upload/part1", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("etag", "\"etag1\"")
        |> Plug.Conn.resp(200, "")
      end)

      # Mock the completion
      Bypass.expect_once(bypass, "POST", "/v3/storage/upload/complete", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["upload_id"] == "multipart_123"
        assert length(decoded["parts"]) == 1

        TestHelpers.json_response(conn, 200, %{
          "access_url" => "https://storage.fal.ai/files/multipart_123/file.bin"
        })
      end)

      # Now the upload should succeed
      assert {:ok, url} = Storage.upload(storage, large_binary, file_name: "file.bin")
      assert url == "https://storage.fal.ai/files/multipart_123/file.bin"
    end
  end

  describe "upload/3 with options" do
    test "includes custom filename for binary uploads", %{bypass: bypass, storage: storage} do
      binary_data = <<1, 2, 3, 4, 5>>
      custom_filename = "my_custom_file.dat"

      Bypass.expect_once(bypass, "POST", "/v3/storage/upload", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body =~ custom_filename

        TestHelpers.json_response(conn, 200, %{
          "access_url" => "https://storage.fal.ai/files/123/#{custom_filename}"
        })
      end)

      opts = [file_name: custom_filename]
      assert {:ok, url} = Storage.upload(storage, binary_data, opts)
      assert url =~ custom_filename
    end
  end

  describe "transform_input/2" do
    test "transforms local file paths to URLs", %{bypass: bypass, storage: storage} do
      # Create test files
      image_path = TestHelpers.create_temp_file(Fixtures.sample_image_binary(), "png")
      audio_path = TestHelpers.create_temp_file("audio data", "mp3")

      input = %{
        "image_url" => image_path,
        "audio_url" => audio_path,
        "prompt" => "This should not be transformed",
        "nested" => %{
          "file_path" => image_path
        }
      }

      # Expect uploads for each unique file
      expected_urls = %{
        image_path => "https://storage.fal.ai/files/img123/image.png",
        audio_path => "https://storage.fal.ai/files/aud456/audio.mp3"
      }

      # Track which files have been uploaded
      {:ok, agent} = Agent.start_link(fn -> MapSet.new() end)

      Bypass.expect(bypass, "POST", "/v3/storage/upload", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)

        url =
          cond do
            body =~ Path.basename(image_path) and
                not MapSet.member?(Agent.get(agent, & &1), image_path) ->
              Agent.update(agent, &MapSet.put(&1, image_path))
              expected_urls[image_path]

            body =~ Path.basename(audio_path) and
                not MapSet.member?(Agent.get(agent, & &1), audio_path) ->
              Agent.update(agent, &MapSet.put(&1, audio_path))
              expected_urls[audio_path]

            true ->
              # Return the already uploaded URL
              if body =~ Path.basename(image_path) do
                expected_urls[image_path]
              else
                expected_urls[audio_path]
              end
          end

        TestHelpers.json_response(conn, 200, %{"access_url" => url})
      end)

      transformed = Storage.transform_input(storage, input)
      assert transformed["image_url"] == expected_urls[image_path]
      assert transformed["audio_url"] == expected_urls[audio_path]
      assert transformed["prompt"] == "This should not be transformed"
      assert transformed["nested"]["file_path"] == expected_urls[image_path]

      # Cleanup
      TestHelpers.cleanup_temp_file(image_path)
      TestHelpers.cleanup_temp_file(audio_path)
      Agent.stop(agent)
    end

    test "handles URLs without transformation", %{storage: storage} do
      input = %{
        "image_url" => "https://example.com/image.png",
        "audio_url" => "http://example.com/audio.mp3",
        "data" => "regular string data"
      }

      transformed = Storage.transform_input(storage, input)
      # Should be unchanged
      assert transformed == input
    end

    test "handles mixed paths and URLs", %{bypass: bypass, storage: storage} do
      file_path = TestHelpers.create_temp_file("test", "txt")

      input = %{
        "file1" => file_path,
        "file2" => "https://example.com/existing.png",
        "settings" => %{
          "path" => file_path,
          "url" => "https://example.com/data.json"
        }
      }

      # Should upload the file path twice (once for each reference)
      Bypass.expect(bypass, "POST", "/v3/storage/upload", fn conn ->
        TestHelpers.json_response(conn, 200, %{
          "access_url" => "https://storage.fal.ai/files/123/test.txt"
        })
      end)

      transformed = Storage.transform_input(storage, input)
      assert transformed["file1"] =~ "https://storage.fal.ai"
      assert transformed["file2"] == "https://example.com/existing.png"
      assert transformed["settings"]["path"] =~ "https://storage.fal.ai"
      assert transformed["settings"]["url"] == "https://example.com/data.json"

      TestHelpers.cleanup_temp_file(file_path)
    end

    test "handles arrays with file paths", %{bypass: bypass, storage: storage} do
      file1 = TestHelpers.create_temp_file("content1", "txt")
      file2 = TestHelpers.create_temp_file("content2", "txt")

      input = %{
        "files" => [file1, file2, "https://example.com/file3.txt"],
        "data" => [%{"path" => file1}, %{"url" => "https://example.com/data.json"}]
      }

      # Track uploaded files
      {:ok, agent} = Agent.start_link(fn -> MapSet.new() end)

      Bypass.expect(bypass, "POST", "/v3/storage/upload", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)

        file_num =
          cond do
            body =~ Path.basename(file1) and not MapSet.member?(Agent.get(agent, & &1), file1) ->
              Agent.update(agent, &MapSet.put(&1, file1))
              "111"

            body =~ Path.basename(file2) and not MapSet.member?(Agent.get(agent, & &1), file2) ->
              Agent.update(agent, &MapSet.put(&1, file2))
              "222"

            true ->
              # Re-upload of file1
              "111"
          end

        TestHelpers.json_response(conn, 200, %{
          "access_url" => "https://storage.fal.ai/files/#{file_num}/file.txt"
        })
      end)

      transformed = Storage.transform_input(storage, input)
      assert is_list(transformed["files"])
      assert Enum.at(transformed["files"], 0) =~ "https://storage.fal.ai"
      assert Enum.at(transformed["files"], 1) =~ "https://storage.fal.ai"
      assert Enum.at(transformed["files"], 2) == "https://example.com/file3.txt"

      TestHelpers.cleanup_temp_file(file1)
      TestHelpers.cleanup_temp_file(file2)
      Agent.stop(agent)
    end

    test "preserves non-string values", %{storage: storage} do
      input = %{
        "number" => 42,
        "boolean" => true,
        "null" => nil,
        "array_of_numbers" => [1, 2, 3],
        "nested" => %{
          "float" => 3.14,
          "bool" => false
        }
      }

      transformed = Storage.transform_input(storage, input)
      assert transformed == input
    end
  end

  describe "error handling" do
    test "handles upload failures", %{bypass: bypass, storage: storage} do
      file_path = TestHelpers.create_temp_file("test", "txt")

      Bypass.expect_once(bypass, "POST", "/v3/storage/upload", fn conn ->
        TestHelpers.json_response(conn, 500, %{
          "error" => %{
            "message" => "Storage service unavailable",
            "code" => "STORAGE_ERROR"
          }
        })
      end)

      assert {:error, _} = Storage.upload(storage, file_path)

      TestHelpers.cleanup_temp_file(file_path)
    end

    test "handles rate limiting with retry information", %{bypass: bypass, storage: storage} do
      file_path = TestHelpers.create_temp_file("test", "txt")

      Bypass.expect_once(bypass, "POST", "/v3/storage/upload", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "60")
        |> TestHelpers.json_response(429, Fixtures.rate_limit_error())
      end)

      assert {:error, _} = Storage.upload(storage, file_path)

      TestHelpers.cleanup_temp_file(file_path)
    end
  end
end
