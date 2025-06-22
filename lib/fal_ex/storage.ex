defmodule FalEx.Storage do
  @moduledoc """
  Storage client for handling file uploads and transformations.

  Automatically uploads files to fal.ai storage and transforms input
  payloads to replace file references with URLs.
  """

  alias FalEx.{Config, Request}

  defstruct [:config]

  @type t :: %__MODULE__{
          config: Config.t()
        }

  # 10MB chunks
  @chunk_size 10 * 1024 * 1024
  # 90MB threshold for multipart
  @multipart_threshold 90 * 1024 * 1024

  @doc """
  Creates a new storage client.
  """
  def create(%Config{} = config) do
    %__MODULE__{config: config}
  end

  @doc """
  Uploads a file to fal.ai storage.

  ## Parameters

    * `data` - Binary file data or a file path
    * `opts` - Upload options

  ## Options

    * `:file_name` - Name of the file
    * `:content_type` - MIME type of the file

  ## Examples

      {:ok, url} = Storage.upload(storage, File.read!("image.png"),
        file_name: "image.png",
        content_type: "image/png"
      )
  """
  @spec upload(t(), binary() | Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def upload(%__MODULE__{} = storage, data_or_path, opts \\ []) do
    cond do
      is_binary(data_or_path) and looks_like_path?(data_or_path) ->
        upload_file(storage, data_or_path, opts)

      is_binary(data_or_path) ->
        do_upload(storage, data_or_path, opts)

      true ->
        {:error, :invalid_input}
    end
  rescue
    _e in ArgumentError ->
      {:error, :badarg}
  end

  defp looks_like_path?(str) do
    String.contains?(str, "/") or String.contains?(str, "\\") or File.exists?(str)
  end

  defp upload_file(storage, path, opts) do
    case File.read(path) do
      {:ok, data} ->
        opts = Keyword.put_new(opts, :file_name, Path.basename(path))
        do_upload(storage, data, opts)

      error ->
        error
    end
  end

  defp do_upload(%__MODULE__{} = storage, data, opts) do
    file_name = Keyword.get(opts, :file_name, generate_file_name())
    content_type = Keyword.get(opts, :content_type) || detect_content_type(data, file_name)
    size = byte_size(data)

    if size > @multipart_threshold do
      multipart_upload(storage, data, file_name, content_type)
    else
      simple_upload(storage, data, file_name, content_type)
    end
  end

  @doc """
  Transforms input data by uploading any file references.

  Recursively processes the input, uploading any binary data or file paths
  and replacing them with URLs.

  ## Examples

      input = %{
        prompt: "A cat",
        image: File.read!("cat.jpg")
      }
      
      transformed = Storage.transform_input(storage, input)
      # => %{prompt: "A cat", image: "https://fal.media/..."}
  """
  @spec transform_input(t(), any()) :: any()
  def transform_input(%__MODULE__{} = storage, input) when is_map(input) do
    Map.new(input, fn {key, value} ->
      {key, transform_input(storage, value)}
    end)
  end

  def transform_input(%__MODULE__{} = storage, input) when is_list(input) do
    Enum.map(input, &transform_input(storage, &1))
  end

  def transform_input(%__MODULE__{} = storage, input) when is_binary(input) do
    transform_binary_input(storage, input)
  end

  def transform_input(_storage, input), do: input

  # Private functions

  defp transform_binary_input(storage, input) do
    cond do
      url?(input) -> input
      File.exists?(input) -> upload_or_keep(storage, input)
      String.printable?(input) -> input
      true -> upload_or_keep(storage, input)
    end
  end

  defp url?(input) do
    String.starts_with?(input, "http://") or String.starts_with?(input, "https://")
  end

  defp upload_or_keep(storage, input) do
    case upload(storage, input) do
      {:ok, url} -> url
      {:error, _} -> input
    end
  end

  defp simple_upload(storage, data, file_name, content_type) do
    url =
      Request.build_url("storage/upload", %{
        subdomain: "v3",
        base_url: get_storage_base_url(storage.config)
      })

    # Build multipart form
    multipart =
      Tesla.Multipart.new()
      |> Tesla.Multipart.add_file_content(data, file_name,
        name: "file",
        headers: [{"content-type", content_type}]
      )

    case upload_multipart_request(storage.config, url, multipart) do
      {:ok, %{"access_url" => access_url}} ->
        {:ok, access_url}

      {:ok, response} ->
        {:error, "Unexpected response: #{inspect(response)}"}

      error ->
        error
    end
  end

  defp multipart_upload(storage, data, file_name, content_type) do
    # Initiate multipart upload
    case initiate_multipart_upload(storage, file_name, content_type, byte_size(data)) do
      {:ok, %{"upload_id" => upload_id, "parts" => parts}} ->
        # Upload chunks and collect ETags
        case upload_chunks_with_etags(storage, data, parts, []) do
          {:ok, completed_parts} ->
            # Complete multipart upload
            complete_multipart_upload(storage, upload_id, file_name, completed_parts)

          error ->
            error
        end

      error ->
        error
    end
  rescue
    _e in ArgumentError ->
      {:error, :badarg}
  end

  defp initiate_multipart_upload(storage, file_name, content_type, file_size) do
    url =
      Request.build_url("storage/upload/initiate", %{
        subdomain: "v3",
        base_url: get_storage_base_url(storage.config)
      })

    body = %{
      "file_name" => file_name,
      "content_type" => content_type,
      "file_size" => file_size
    }

    Request.dispatch_request(%{
      method: :post,
      target_url: url,
      input: body,
      config: storage.config
    })
  end

  defp upload_chunks_with_etags(_storage, _data, [], completed),
    do: {:ok, Enum.reverse(completed)}

  defp upload_chunks_with_etags(storage, data, [part | rest], completed) do
    %{"part_number" => part_number, "upload_url" => upload_url} = part

    # Calculate chunk boundaries
    chunk_start = (part_number - 1) * @chunk_size
    chunk_end = min(chunk_start + @chunk_size, byte_size(data))
    chunk_size = chunk_end - chunk_start

    # Skip if chunk would be empty
    if chunk_size <= 0 do
      upload_chunks_with_etags(storage, data, rest, completed)
    else
      chunk = binary_part(data, chunk_start, chunk_size)

      # Upload chunk
      case upload_chunk(upload_url, chunk) do
        {:ok, etag} ->
          completed_part = %{
            "part_number" => part_number,
            "etag" => etag
          }

          upload_chunks_with_etags(storage, data, rest, [completed_part | completed])

        error ->
          error
      end
    end
  end

  defp upload_chunk(upload_url, chunk) do
    # Direct PUT to presigned URL
    case Tesla.put(upload_url, chunk) do
      {:ok, %Tesla.Env{status: status, headers: headers}} when status in 200..299 ->
        # Extract ETag from response headers
        etag = get_header_value(headers, "etag", "\"\"")
        {:ok, etag}

      {:ok, %Tesla.Env{status: status}} ->
        {:error, "Chunk upload failed with status #{status}"}

      error ->
        error
    end
  end

  defp get_header_value(headers, key, default) do
    Enum.find_value(headers, default, fn {k, v} ->
      if String.downcase(k) == String.downcase(key), do: v
    end)
  end

  defp complete_multipart_upload(storage, upload_id, file_name, parts) do
    url =
      Request.build_url("storage/upload/complete", %{
        subdomain: "v3",
        base_url: get_storage_base_url(storage.config)
      })

    body = %{
      "upload_id" => upload_id,
      "file_name" => file_name,
      "parts" => parts
    }

    case Request.dispatch_request(%{
           method: :post,
           target_url: url,
           input: body,
           config: storage.config
         }) do
      {:ok, %{"access_url" => access_url}} ->
        {:ok, access_url}

      error ->
        error
    end
  end

  defp upload_multipart_request(config, url, multipart) do
    middleware = [
      {Tesla.Middleware.Headers, [{"Authorization", get_auth_header(config)}]}
    ]

    client = Tesla.client(middleware)

    case Tesla.post(client, url, multipart) do
      {:ok, %Tesla.Env{status: status, body: body}} when status in 200..299 ->
        Jason.decode(body)

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, "Upload failed with status #{status}: #{body}"}

      error ->
        error
    end
  end

  defp get_auth_header(config) do
    case FalEx.Auth.get_request_headers(config) do
      [{"Authorization", value} | _] -> value
      _ -> ""
    end
  end

  defp get_storage_base_url(config) do
    base_url = Config.get_base_url(config)
    # For localhost (testing), keep the same URL
    # For production, use the CDN subdomain
    if String.contains?(base_url, "localhost") do
      base_url
    else
      String.replace(base_url, "fal.run", "fal-cdn.com")
    end
  end

  defp generate_file_name do
    "file_#{:os.system_time(:nanosecond)}"
  end

  defp detect_content_type(data, file_name) do
    # Try to detect from file extension first
    case detect_from_extension(file_name) do
      nil ->
        # Try to detect from binary data using Infer
        case Infer.get(data) do
          %Infer.Type{mime_type: mime_type} -> mime_type
          _ -> "application/octet-stream"
        end

      mime_type ->
        mime_type
    end
  end

  defp detect_from_extension(file_name) do
    extension_map = %{
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".png" => "image/png",
      ".gif" => "image/gif",
      ".webp" => "image/webp",
      ".mp4" => "video/mp4",
      ".webm" => "video/webm",
      ".mp3" => "audio/mpeg",
      ".wav" => "audio/wav",
      ".pdf" => "application/pdf",
      ".json" => "application/json",
      ".txt" => "text/plain"
    }

    Map.get(extension_map, Path.extname(file_name))
  end
end
