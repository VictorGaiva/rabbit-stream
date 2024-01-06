defmodule RabbitMQStream.Message.Decoder do
  @moduledoc false
  import RabbitMQStream.Message.Helpers
  alias RabbitMQStream.Message.Data

  alias RabbitMQStream.Message.{Response, Request}

  def decode(buffer) do
    <<key::unsigned-integer-size(16), version::unsigned-integer-size(16), buffer::binary>> = buffer

    command = decode_command(key)

    if Bitwise.band(key, 0b1000_0000_0000_0000) > 0 do
      %Response{version: version, command: command}
    else
      %Request{version: version, command: command}
    end
    |> decode(buffer)
  end

  def decode(%Response{command: command} = response, buffer)
      when command in [
             :close,
             :create_stream,
             :delete_stream,
             :declare_publisher,
             :delete_publisher,
             :subscribe,
             :unsubscribe,
             :credit,
             :query_offset,
             :query_publisher_sequence,
             :peer_properties,
             :sasl_handshake,
             :sasl_authenticate,
             :open,
             :route,
             :partitions,
             :exchange_command_versions
           ] do
    <<correlation_id::unsigned-integer-size(32), code::unsigned-integer-size(16), buffer::binary>> = buffer

    %{
      response
      | data: Data.decode(response, buffer),
        correlation_id: correlation_id,
        code: decode_code(code)
    }
  end

  def decode(%{command: command} = response, buffer)
      when command in [:close, :query_metadata] do
    <<correlation_id::unsigned-integer-size(32), buffer::binary>> = buffer

    %{response | data: Data.decode(response, buffer), correlation_id: correlation_id}
  end

  def decode(%{command: command} = action, buffer)
      when command in [
             :tune,
             :heartbeat,
             :metadata_update,
             :publish_confirm,
             :publish_error,
             :deliver,
             :store_offset
           ] do
    %{action | data: Data.decode(action, buffer)}
  end
end
