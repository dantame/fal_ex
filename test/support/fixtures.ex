defmodule FalEx.Fixtures do
  @moduledoc """
  Test fixtures that mirror the JavaScript fal-js library responses.
  Based on the official fal-js test suite.
  """

  @doc """
  Model endpoints used in tests
  """
  def model_endpoints do
    %{
      fast_sdxl: "fal-ai/fast-sdxl",
      flux_pro: "fal-ai/flux/pro",
      whisper: "fal-ai/whisper",
      llava: "fal-ai/llava-v1.6-34b"
    }
  end

  @doc """
  Sample model input for image generation
  """
  def image_generation_input do
    %{
      "prompt" => "a cute robot playing with a cat, digital art",
      "negative_prompt" => "ugly, blurry, low quality",
      "image_size" => "landscape_4_3",
      "num_inference_steps" => 25,
      "guidance_scale" => 7.5,
      "num_images" => 1,
      "enable_safety_checker" => true
    }
  end

  @doc """
  Sample model input for audio transcription
  """
  def audio_transcription_input do
    %{
      "audio_url" => "https://example.com/audio.mp3",
      "task" => "transcribe",
      "language" => "en",
      "chunk_level" => "segment",
      "version" => "3"
    }
  end

  @doc """
  Sample model input for vision language model
  """
  def vision_language_input do
    %{
      "image_url" => "https://example.com/image.jpg",
      "prompt" => "What is in this image?",
      "max_tokens" => 512,
      "temperature" => 0.7
    }
  end

  @doc """
  Mock successful image generation response
  """
  def image_generation_response do
    %{
      "images" => [
        %{
          "url" => "https://storage.fal.ai/outputs/123/image_0.png",
          "width" => 1024,
          "height" => 768,
          "content_type" => "image/png"
        }
      ],
      "timings" => %{
        "inference" => 2.5
      },
      "has_nsfw_concepts" => [false],
      "prompt" => "a cute robot playing with a cat, digital art",
      "seed" => 42
    }
  end

  @doc """
  Mock successful audio transcription response
  """
  def audio_transcription_response do
    %{
      "text" => "Hello, this is a test transcription.",
      "chunks" => [
        %{
          "timestamp" => [0.0, 3.0],
          "text" => "Hello, this is a test transcription."
        }
      ],
      "language" => "en",
      "duration" => 3.0
    }
  end

  @doc """
  Mock successful vision language response
  """
  def vision_language_response do
    %{
      "output" =>
        "The image shows a cute robot playing with an orange tabby cat. The robot appears to be made of white and blue plastic with LED eyes, and is gently petting the cat who seems to be enjoying the interaction.",
      "usage" => %{
        "prompt_tokens" => 15,
        "completion_tokens" => 45,
        "total_tokens" => 60
      }
    }
  end

  @doc """
  Mock rate limit error response
  """
  def rate_limit_error do
    %{
      "error" => %{
        "message" => "Rate limit exceeded. Please try again later.",
        "code" => "RATE_LIMIT_EXCEEDED",
        "details" => %{
          "retry_after" => 60,
          "limit" => 100,
          "remaining" => 0,
          "reset" => "2024-01-01T13:00:00Z"
        }
      }
    }
  end

  @doc """
  Mock validation error response
  """
  def validation_error do
    %{
      "error" => %{
        "message" => "Invalid input parameters",
        "code" => "VALIDATION_ERROR",
        "details" => %{
          "fields" => %{
            "prompt" => ["Required field missing"],
            "num_images" => ["Must be between 1 and 4"]
          }
        }
      }
    }
  end

  @doc """
  Mock authentication error
  """
  def auth_error do
    %{
      "error" => %{
        "message" => "Invalid API key",
        "code" => "UNAUTHORIZED",
        "details" => %{
          "hint" => "Make sure you're using a valid API key from https://fal.ai/dashboard/keys"
        }
      }
    }
  end

  @doc """
  Mock queue position updates for testing subscribe
  """
  def queue_position_updates do
    [
      %{"status" => "IN_QUEUE", "queue_position" => 10},
      %{"status" => "IN_QUEUE", "queue_position" => 5},
      %{"status" => "IN_QUEUE", "queue_position" => 1},
      %{"status" => "IN_PROGRESS", "logs" => [%{"message" => "Starting..."}]},
      %{"status" => "IN_PROGRESS", "logs" => [%{"message" => "Processing..."}]},
      %{"status" => "COMPLETED"}
    ]
  end

  @doc """
  Mock streaming events for SSE
  """
  def streaming_events do
    [
      %{
        "type" => "start",
        "data" => %{"request_id" => "stream_123", "model" => "fal-ai/fast-sdxl"}
      },
      %{
        "type" => "progress",
        "data" => %{"percentage" => 25, "message" => "Loading model..."}
      },
      %{
        "type" => "progress",
        "data" => %{"percentage" => 50, "message" => "Generating image..."}
      },
      %{
        "type" => "progress",
        "data" => %{"percentage" => 75, "message" => "Post-processing..."}
      },
      %{
        "type" => "output",
        "data" => image_generation_response()
      },
      %{
        "type" => "complete",
        "data" => %{"duration" => 3.2, "request_id" => "stream_123"}
      }
    ]
  end

  @doc """
  Mock WebSocket messages for realtime connection
  """
  def websocket_messages do
    [
      %{
        "type" => "connection",
        "data" => %{"status" => "connected", "connection_id" => "conn_123"}
      },
      %{
        "type" => "model_loading",
        "data" => %{"status" => "loading", "progress" => 0.5}
      },
      %{
        "type" => "model_ready",
        "data" => %{"status" => "ready", "model" => "fal-ai/fast-sdxl"}
      },
      %{
        "type" => "inference_start",
        "data" => %{"request_id" => "inf_123"}
      },
      %{
        "type" => "inference_progress",
        "data" => %{"request_id" => "inf_123", "progress" => 0.5}
      },
      %{
        "type" => "inference_complete",
        "data" => %{"request_id" => "inf_123", "result" => image_generation_response()}
      }
    ]
  end

  @doc """
  Binary file content for upload tests
  """
  def sample_image_binary do
    # 1x1 red PNG
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 2,
      0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 8, 29, 99, 248, 15, 0, 0, 1, 1, 1,
      0, 24, 221, 141, 176, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end

  @doc """
  Sample text file content
  """
  def sample_text_content do
    "This is a test file for FalEx upload functionality.\nIt contains multiple lines.\nAnd some special characters: !@#$%^&*()"
  end
end
