# FalEx

An Elixir client for [fal.ai](https://fal.ai) - Serverless AI/ML inference platform.

[![Hex.pm](https://img.shields.io/hexpm/v/fal_ex.svg)](https://hex.pm/packages/fal_ex)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/fal_ex)
[![License](https://img.shields.io/hexpm/l/fal_ex.svg)](https://github.com/dantame/fal_ex/blob/master/LICENSE)

## About

FalEx provides a robust and user-friendly Elixir client for seamless integration with fal.ai endpoints. It supports synchronous execution, queued jobs, streaming responses, real-time WebSocket connections, and automatic file handling.

## Features

- 🚀 **Simple API** - Intuitive interface matching the JavaScript client
- 📦 **Queue Support** - Submit long-running jobs and poll for results
- 🌊 **Streaming** - Real-time streaming responses with Server-Sent Events
- 🔌 **WebSocket** - Bidirectional real-time communication
- 📤 **File Uploads** - Automatic file upload and URL transformation
- 🔐 **Secure** - API key authentication with proxy support
- 🧩 **Type Safe** - Full type specifications for better developer experience

## Installation

Add `fal_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fal_ex, "~> 0.1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Configuration

### Application Configuration (Recommended)

Configure FalEx in your application's config files:

```elixir
# config/config.exs
config :fal_ex,
  api_key: "your-api-key"

# config/runtime.exs (for runtime configuration)
import Config

if config_env() == :prod do
  config :fal_ex,
    api_key: System.fetch_env!("FAL_KEY")
end
```

### Environment Variables

You can also use environment variables (these override application config):

```bash
# Single API key
export FAL_KEY="your-api-key"

# Or using key ID and secret
export FAL_KEY_ID="your-key-id"
export FAL_KEY_SECRET="your-key-secret"
```

### Programmatic Configuration

Configure the client programmatically at runtime:

```elixir
# Configure globally
FalEx.config(credentials: "your-api-key")

# Or with more options
FalEx.config(
  credentials: {"key-id", "key-secret"},
  proxy_url: "/api/fal/proxy"
)
```

### Creating a Custom Client

For more control, create a custom client instance:

```elixir
config = FalEx.Config.new(
  credentials: System.get_env("FAL_KEY"),
  base_url: "https://fal.run"
)

client = FalEx.Client.create(config)
```

## Basic Usage

### Synchronous Execution

Run models synchronously (blocks until complete):

```elixir
{:ok, result} = FalEx.run("fal-ai/fast-sdxl",
  input: %{
    prompt: "A serene mountain landscape at sunset",
    image_size: "landscape_16_9"
  }
)

IO.inspect(result["images"])
```

### Queue-Based Execution

For long-running models or when you want progress updates, use the queue system:

```elixir
{:ok, result} = FalEx.subscribe("fal-ai/flux/dev",
  input: %{
    prompt: "A detailed architectural drawing",
    num_images: 4
  },
  logs: true,
  on_queue_update: fn status ->
    IO.puts("Status: #{inspect(status.status)}")
    
    # Print logs if available
    Enum.each(status[:logs] || [], fn log ->
      IO.puts("[#{log["level"]}] #{log["message"]}")
    end)
  end
)

# Note: For fast models, the request may complete synchronously
# and you'll get the result immediately with a single status update
```

### Streaming Responses

Stream partial results from compatible models (requires endpoints that support SSE streaming):

```elixir
# Get the stream
{:ok, stream} = FalEx.stream("fal-ai/flux/dev",
  input: %{
    prompt: "A beautiful sunset over mountains",
    image_size: "landscape_4_3",
    num_images: 1
  }
)

# Process events as they arrive
stream
|> Stream.each(fn event ->
  IO.inspect(event, label: "Stream event")
  
  # Events typically have a "type" field indicating progress
  case event do
    %{"type" => "progress", "data" => data} ->
      IO.puts("Progress: #{inspect(data)}")
    
    %{"type" => "output", "data" => data} ->
      IO.puts("Got output: #{inspect(data["images"])}")
      
    _ ->
      :ok
  end
end)
|> Stream.run()
```

### Real-time WebSocket

For bidirectional communication:

```elixir
{:ok, conn} = FalEx.realtime()
|> FalEx.Realtime.connect("fal-ai/camera-turbo-stream",
  on_message: fn message ->
    IO.inspect(message, label: "Received")
  end,
  on_error: fn error ->
    IO.puts("Error: #{error}")
  end
)

# Send messages
FalEx.Realtime.send(conn, %{
  type: "frame",
  data: base64_encoded_image
})
```

### File Handling

FalEx automatically handles file uploads:

```elixir
# Automatic file upload from path
{:ok, result} = FalEx.run("fal-ai/face-to-sticker",
  input: %{
    image_url: "/path/to/local/image.jpg",  # Automatically uploaded
    prompt: "cartoon style"
  }
)

# Direct binary upload
image_data = File.read!("avatar.png")
{:ok, result} = FalEx.run("fal-ai/image-to-image",
  input: %{
    image: image_data,  # Automatically uploaded
    prompt: "enhance details"
  }
)

# Manual upload
{:ok, url} = FalEx.storage()
|> FalEx.Storage.upload(image_data,
  file_name: "avatar.png",
  content_type: "image/png"
)
```

## Advanced Usage

### Queue Operations

Direct queue API access:

```elixir
queue = FalEx.queue()

# Submit a job
{:ok, %{"request_id" => request_id}} = FalEx.Queue.submit(queue, "fal-ai/fast-sdxl",
  input: %{prompt: "A lighthouse"},
  webhook_url: "https://example.com/webhook"
)

# Check status
{:ok, status} = FalEx.Queue.status(queue, "fal-ai/fast-sdxl",
  request_id: request_id,
  logs: true
)

# Cancel if needed
:ok = FalEx.Queue.cancel(queue, "fal-ai/fast-sdxl",
  request_id: request_id
)

# Get result when complete
{:ok, result} = FalEx.Queue.result(queue, "fal-ai/fast-sdxl",
  request_id: request_id
)
```

### Custom Middleware

Add custom request/response handling:

```elixir
defmodule MyApp.FalMiddleware do
  @behaviour Tesla.Middleware
  
  def call(env, next, _opts) do
    # Add custom header
    env = Tesla.put_header(env, "x-custom-header", "value")
    
    # Call next middleware
    case Tesla.run(env, next) do
      {:ok, env} ->
        # Log response
        Logger.info("FAL Response: #{env.status}")
        {:ok, env}
        
      error ->
        error
    end
  end
end

# Use in config
FalEx.config(
  credentials: "...",
  request_middleware: MyApp.FalMiddleware
)
```

### Error Handling

FalEx provides detailed error types:

```elixir
case FalEx.run("fal-ai/fast-sdxl", input: %{}) do
  {:ok, result} ->
    IO.inspect(result.data)
    
  {:error, %FalEx.Response.ValidationError{} = error} ->
    IO.puts("Validation failed: #{error.message}")
    
    Enum.each(error.errors, fn error ->
      IO.puts("  #{Enum.join(error.loc, ".")}: #{error.msg}")
    end)
    
  {:error, %FalEx.Response.ApiError{} = error} ->
    IO.puts("API error (#{error.status}): #{error.message}")
    
  {:error, reason} ->
    IO.puts("Unexpected error: #{inspect(reason)}")
end
```

### Proxy Configuration

For production deployments, use a proxy to protect your API keys:

```elixir
# Configure client to use proxy
FalEx.config(proxy_url: "/api/fal/proxy")

# In your Phoenix app, add a proxy endpoint
defmodule MyAppWeb.FalProxyController do
  use MyAppWeb, :controller
  
  def proxy(conn, params) do
    # Forward request to fal.ai with server-side credentials
    # Implementation depends on your setup
  end
end
```

## Examples

### Text to Image

```elixir
{:ok, result} = FalEx.run("fal-ai/fast-sdxl",
  input: %{
    prompt: "A futuristic city with flying cars",
    negative_prompt: "blurry, low quality",
    image_size: "square_hd",
    num_inference_steps: 25,
    guidance_scale: 7.5
  }
)

[image | _] = result.data["images"]
IO.puts("Generated image: #{image["url"]}")
```

### Image to Image

```elixir
source_image = File.read!("source.jpg")

{:ok, result} = FalEx.run("fal-ai/image-to-image",
  input: %{
    image: source_image,
    prompt: "Transform to watercolor painting",
    strength: 0.8
  }
)
```

### LLM Streaming

```elixir
FalEx.stream("fal-ai/llama-3",
  input: %{
    prompt: "Explain quantum computing",
    max_tokens: 500,
    temperature: 0.7
  }
)
|> Stream.scan("", fn chunk, acc ->
  text = chunk["text"] || ""
  IO.write(text)
  acc <> text
end)
|> Enum.to_list()
|> List.last()
```

### Whisper Transcription

```elixir
audio_data = File.read!("recording.mp3")

{:ok, result} = FalEx.run("fal-ai/whisper",
  input: %{
    audio: audio_data,
    language: "en",
    task: "transcribe",
    include_timestamps: true
  }
)

IO.puts("Transcription: #{result.data["text"]}")
```

## Available Models

See the [fal.ai model gallery](https://fal.ai/models) for available models and their parameters.

Popular models include:
- `fal-ai/fast-sdxl` - Fast SDXL image generation
- `fal-ai/llama-3` - Meta's Llama 3 language model
- `fal-ai/whisper` - OpenAI's Whisper speech recognition
- `fal-ai/stable-video` - Stable Video Diffusion
- `fal-ai/face-to-sticker` - Convert faces to stickers
- `fal-ai/image-to-image` - Image transformation

## Testing

```bash
# Run tests
mix test

# Run tests with coverage
mix test --cover

# Run dialyzer
mix dialyzer

# Run credo
mix credo
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by the official [fal-js](https://github.com/fal-ai/fal-js) JavaScript client
- Built with [Tesla](https://github.com/elixir-tesla/tesla) HTTP client
- WebSocket support via [WebSockex](https://github.com/Azolo/websockex)

## Support

- 📚 [Documentation](https://hexdocs.pm/fal_ex)
- 🐛 [Issue Tracker](https://github.com/dantame/fal_ex/issues)
