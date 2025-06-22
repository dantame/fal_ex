defmodule FalEx.Response do
  @moduledoc """
  Response handling and error types for FalEx client.
  """

  defmodule ApiError do
    @moduledoc """
    Represents an API error response.
    """
    defexception [:message, :status, :body]

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: opts[:message] || "API error",
        status: opts[:status],
        body: opts[:body]
      }
    end
  end

  defmodule ValidationError do
    @moduledoc """
    Represents a validation error with field-specific details.
    """
    defexception [:message, :errors]

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: opts[:message] || "Validation error",
        errors: opts[:errors] || []
      }
    end
  end

  @doc """
  Creates an API error from response data.
  """
  def api_error(message, status, body) do
    %ApiError{
      message: extract_error_message(body, message),
      status: status,
      body: body
    }
  end

  @doc """
  Creates a validation error from response data.
  """
  def validation_error(body) when is_map(body) do
    errors = extract_validation_errors(body)
    message = format_validation_message(errors)

    %ValidationError{
      message: message,
      errors: errors
    }
  end

  def validation_error(body) do
    %ValidationError{
      message: "Validation failed",
      errors: [%{msg: inspect(body)}]
    }
  end

  @doc """
  Result response handler that wraps the response data.

  This is the default response handler that formats successful
  responses into the standard result format.
  """
  def result_response_handler(%Tesla.Env{status: status, body: body, headers: _headers})
      when status in 200..299 do
    {:ok, body}
  end

  def result_response_handler(%Tesla.Env{status: status, body: body}) do
    # Return errors in the expected format for tests
    {:error, %{status_code: status, body: body}}
  end

  @doc """
  Checks if a queue status indicates completion.
  """
  def completed_queue_status?(%{status: "COMPLETED"}), do: true
  def completed_queue_status?(%{"status" => "COMPLETED"}), do: true
  def completed_queue_status?(_), do: false

  @doc """
  Checks if a response is a queue status response.
  """
  def queue_status?(%{status: status}) when status in ["IN_QUEUE", "IN_PROGRESS", "COMPLETED"],
    do: true

  def queue_status?(%{"status" => status})
      when status in ["IN_QUEUE", "IN_PROGRESS", "COMPLETED"],
      do: true

  def queue_status?(_), do: false

  # Private functions

  defp extract_error_message(%{"detail" => detail}, _default) when is_binary(detail), do: detail
  defp extract_error_message(%{"error" => error}, _default) when is_binary(error), do: error

  defp extract_error_message(%{"message" => message}, _default) when is_binary(message),
    do: message

  defp extract_error_message(_, default), do: default

  defp extract_validation_errors(%{"detail" => details}) when is_list(details) do
    Enum.map(details, &format_validation_error/1)
  end

  defp extract_validation_errors(_), do: []

  defp format_validation_error(%{"loc" => loc, "msg" => msg, "type" => type}) do
    %{
      loc: loc,
      msg: msg,
      type: type
    }
  end

  defp format_validation_error(error), do: %{msg: inspect(error)}

  defp format_validation_message([]), do: "Validation failed"

  defp format_validation_message(errors) do
    messages =
      Enum.map(errors, fn
        %{loc: loc, msg: msg} when is_list(loc) and length(loc) > 0 ->
          "#{Enum.join(loc, ".")}: #{msg}"

        %{msg: msg} ->
          msg

        _ ->
          "Unknown validation error"
      end)

    "Validation failed: #{Enum.join(messages, "; ")}"
  end
end
