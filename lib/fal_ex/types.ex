defmodule FalEx.Types do
  @moduledoc """
  Type definitions for the FalEx client library.
  """

  @type endpoint_id :: String.t()
  @type request_id :: String.t()

  @type input :: map() | keyword() | nil
  @type output :: any()

  @type run_options :: %{
          optional(:input) => input(),
          optional(:path) => String.t(),
          optional(:method) => :get | :post,
          optional(:query) => map(),
          optional(:abort_signal) => reference(),
          optional(:request_strategy) => String.t()
        }

  @type result :: map()

  @type queue_status ::
          :in_queue
          | :in_progress
          | :completed

  @type queue_status_response :: %{
          status: queue_status(),
          request_id: request_id(),
          response_url: String.t() | nil,
          logs: list(log_entry()) | nil,
          metrics: metrics() | nil
        }

  @type completed_queue_status :: %{
          status: :completed,
          request_id: request_id(),
          response_url: String.t(),
          logs: list(log_entry()),
          metrics: metrics()
        }

  @type log_entry :: %{
          message: String.t(),
          level: String.t(),
          timestamp: String.t(),
          source: String.t()
        }

  @type metrics :: %{
          inference_time: number() | nil,
          queue_time: number() | nil,
          total_time: number() | nil
        }

  @type webhook_response :: %{
          request_id: request_id(),
          status: queue_status(),
          payload: output() | nil,
          error: String.t() | nil,
          metrics: metrics() | nil
        }

  @type validation_error_info :: %{
          loc: list(String.t() | integer()),
          msg: String.t(),
          type: String.t()
        }

  @type storage_file :: %{
          file_name: String.t(),
          file_size: integer(),
          file_data: binary(),
          content_type: String.t() | nil
        }

  @type url_options :: %{
          optional(:subdomain) => String.t(),
          optional(:path) => String.t()
        }
end
