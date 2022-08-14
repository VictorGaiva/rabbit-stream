defmodule RabbitMQStream.Connection.Handler do
  @moduledoc false

  require Logger
  alias RabbitMQStream.Connection
  alias RabbitMQStream.Message

  @ok 0x01
  @stream_does_not_exist 0x02
  @subscription_id_already_exists 0x03
  @subscription_id_does_not_exist 0x04
  @stream_already_exists 0x05
  @stream_not_available 0x06
  @sasl_mechanism_not_supported 0x07
  @authentication_failure 0x08
  @sasl_error 0x09
  @sasl_challenge 0x0A
  @sasl_authentication_failure_loopback 0x0B
  @virtual_host_access_failure 0x0C
  @unknown_frame 0x0D
  @frame_too_large 0x0E
  @internal_error 0x0F
  @access_refused 0x10
  @precondition_failed 0x11
  @publisher_does_not_exist 0x12
  @no_offset 0x13

  @mapper %{
    @ok => :ok,
    @stream_does_not_exist => :stream_does_not_exist,
    @subscription_id_already_exists => :subscription_id_already_exists,
    @subscription_id_does_not_exist => :subscription_id_does_not_exist,
    @stream_already_exists => :stream_already_exists,
    @stream_not_available => :stream_not_available,
    @sasl_mechanism_not_supported => :sasl_mechanism_not_supported,
    @authentication_failure => :authentication_failure,
    @sasl_error => :sasl_error,
    @sasl_challenge => :sasl_challenge,
    @sasl_authentication_failure_loopback => :sasl_authentication_failure_loopback,
    @virtual_host_access_failure => :virtual_host_access_failure,
    @unknown_frame => :unknown_frame,
    @frame_too_large => :frame_too_large,
    @internal_error => :internal_error,
    @access_refused => :access_refused,
    @precondition_failed => :precondition_failed,
    @publisher_does_not_exist => :publisher_does_not_exist,
    @no_offset => :no_offset
  }

  def handle_message({:request, correlation_id, {:close, code, reason}}, conn) do
    Logger.debug("Connection close requested by server: #{code} #{reason}")
    Logger.debug("Connection closed")

    %{conn | state: :closing}
    |> send_response(:close, correlation_id: correlation_id, code: :ok)
    |> handle_closed(reason)
  end

  def handle_message({:request, _, {:tune, frame_max, heartbeat}}, conn) do
    Logger.debug("Tunning complete. Starting heartbeat timer.")

    Process.send_after(self(), {:heartbeat}, conn.options[:heartbeat] * 1000)

    options = Keyword.merge(conn.options, frame_max: frame_max, heartbeat: heartbeat)

    %{conn | options: options}
  end

  def handle_message({:request, :heartbeat}, conn) do
    conn
  end

  # wtf is this '_code?'
  def handle_message({:metadata_update, stream_name, _code?}, conn) do
    conn
    |> send_request(:query_metadata, streams: [stream_name])
  end

  def handle_message({:request, {:deliver, subscription_id, data}}, conn) do
    pid = Map.get(conn.subscriptions, subscription_id)

    if pid != nil do
      Process.send(pid, data, [:noconnect])
    end

    conn
  end

  def handle_message({:publish_confirm, _publisher_id, _publishing_ids} = _response, conn) do
    conn
  end

  def handle_message({:publish_error, _publisher_id, _code, _publishing_ids} = _response, conn) do
    conn
  end

  def handle_message({:response, correlation_id, {:close, _code}}, conn) do
    Logger.debug("Connection closed: #{conn.options[:host]}:#{conn.options[:port]}")

    {{pid, _data}, conn} = pop_request_tracker(conn, :close, correlation_id)

    conn = %{conn | state: :closed, socket: nil}

    GenServer.reply(pid, :ok)

    conn
  end

  def handle_message({:response, _, command}, conn)
      when tuple_size(command) >= 2 and
             elem(command, 1) in [
               @sasl_mechanism_not_supported,
               @authentication_failure,
               @sasl_error,
               @sasl_challenge,
               @sasl_authentication_failure_loopback,
               @virtual_host_access_failure
             ] do
    Logger.error("Failed to connect to #{conn.options[:host]}:#{conn.options[:port]}. Reason: #{elem(command, 1)}")

    for request <- conn.connect_requests do
      GenServer.reply(request, {:error, @mapper[elem(command, 1)]})
    end

    %{conn | state: :closed, socket: nil, connect_requests: []}
  end

  def handle_message({:response, correlation_id, command}, conn)
      when elem(command, 0) in [
             :create_stream,
             :delete_stream,
             :query_offset,
             :declare_publisher,
             :delete_publisher,
             :subscribe,
             :unsubscribe
           ] and
             tuple_size(command) >= 2 and
             elem(command, 1) != @ok do
    {{pid, _data}, conn} = pop_request_tracker(conn, elem(command, 0), correlation_id)

    if pid != nil do
      GenServer.reply(pid, {:error, @mapper[elem(command, 1)]})
    end

    conn
  end

  def handle_message(_, %Connection{state: :closed} = conn) do
    Logger.error("Message received on a closed connection")

    conn
  end

  def handle_message({:response, _correlation_id, {:peer_properties, _code, peer_properties}}, conn) do
    Logger.debug("Exchange successful.")
    Logger.debug("Initiating SASL handshake.")

    %{conn | peer_properties: peer_properties}
    |> send_request(:sasl_handshake)
  end

  def handle_message({:response, _correlation_id, {:sasl_handshake, _code, mechanisms}}, conn) do
    Logger.debug("SASL handshake successful. Initiating authentication.")

    %{conn | mechanisms: mechanisms}
    |> send_request(:sasl_authenticate)
  end

  def handle_message({:response, _correlation_id, {:sasl_authenticate, _code}}, conn) do
    Logger.debug("Authentication successful. Initiating connection tuning.")

    conn
  end

  def handle_message({:response, _correlation_id, {:sasl_authenticate, _code, _}}, conn) do
    Logger.debug("Authentication successful. Skipping connection tuning.")
    Logger.debug("Opening connection to vhost: \"#{conn.options[:vhost]}\"")

    conn
    |> send_request(:open)
    |> Map.put(:state, :opening)
  end

  def handle_message({:tune, frame_max, heartbeat}, conn) do
    Logger.debug("Tunning data received. Starting heartbeat timer.")
    Logger.debug("Opening connection to vhost: \"#{conn.options[:vhost]}\"")

    options = Keyword.merge(conn.options, frame_max: frame_max, heartbeat: heartbeat)

    %{conn | options: options}
    |> send_response(:tune, correlation_id: 0)
    |> Map.put(:state, :opening)
    |> send_request(:open)
  end

  def handle_message({:response, _correlation_id, {:open, _code, connection_properties}}, conn) do
    Logger.debug("Successfully opened connection with vhost: \"#{conn.options[:vhost]}\"")

    for request <- conn.connect_requests do
      GenServer.reply(request, :ok)
    end

    %{conn | state: :open, connect_requests: [], connection_properties: connection_properties}
  end

  def handle_message({:response, correlation_id, {:metadata, brokers, streams}}, conn) do
    {{pid, _data}, conn} = pop_request_tracker(conn, :query_metadata, correlation_id)

    brokers = Map.new(brokers)

    if pid != nil do
      GenServer.reply(pid, {:ok, %{brokers: brokers, streams: streams}})
    end

    %{conn | brokers: Map.merge(conn.brokers, brokers), streams: Map.merge(conn.streams, streams)}
  end

  def handle_message({:response, correlation_id, {:query_offset, _, offset}}, conn) do
    {{pid, _data}, conn} = pop_request_tracker(conn, :query_offset, correlation_id)

    if pid != nil do
      GenServer.reply(pid, {:ok, offset})
    end

    conn
  end

  def handle_message({:response, correlation_id, {:declare_publisher, _code}}, conn) do
    {{pid, id}, conn} = pop_request_tracker(conn, :declare_publisher, correlation_id)

    if pid != nil do
      GenServer.reply(pid, {:ok, id})
    end

    conn
  end

  def handle_message({:response, correlation_id, {:query_publisher_sequence, _code, sequence}}, conn) do
    {{pid, _data}, conn} = pop_request_tracker(conn, :query_publisher_sequence, correlation_id)

    if pid != nil do
      GenServer.reply(pid, {:ok, sequence})
    end

    conn
  end

  def handle_message({:response, correlation_id, {:subscribe, _code}}, conn) do
    {{pid, data}, conn} = pop_request_tracker(conn, :subscribe, correlation_id)

    {subscription_id, subscriber} = data

    if pid != nil do
      GenServer.reply(pid, {:ok, subscription_id})
    end

    %{conn | subscriptions: Map.put(conn.subscriptions, subscription_id, subscriber)}
  end

  def handle_message({:response, correlation_id, command}, conn)
      when elem(command, 0) in [:create_stream, :delete_stream, :delete_publisher, :unsubscribe] do
    {{pid, _data}, conn} = pop_request_tracker(conn, elem(command, 0), correlation_id)

    if pid != nil do
      GenServer.reply(pid, :ok)
    end

    conn
  end

  def push_request_tracker(%Connection{} = conn, type, from, data \\ nil) when is_atom(type) when is_pid(from) do
    request_tracker = Map.put(conn.request_tracker, {type, conn.correlation_sequence}, {from, data})

    %{conn | request_tracker: request_tracker}
  end

  def pop_request_tracker(%Connection{} = conn, type, correlation) when is_atom(type) do
    {entry, request_tracker} = Map.pop(conn.request_tracker, {type, correlation}, {nil, nil})

    {entry, %{conn | request_tracker: request_tracker}}
  end

  def handle_closed(%Connection{} = conn, reason) do
    for request <- conn.connect_requests do
      GenServer.reply(request, {:error, :closed})
    end

    for {client, _data} <- Map.values(conn.request_tracker) do
      GenServer.reply(client, {:error, reason})
    end

    %{conn | request_tracker: %{}, connect_requests: []}
  end

  def send_request(%Connection{} = conn, command, opts \\ []) do
    {correlation_sum, opts} = Keyword.pop(opts, :correlation_sum, 1)
    {publisher_sum, opts} = Keyword.pop(opts, :publisher_sum, 0)
    {subscriber_sum, opts} = Keyword.pop(opts, :subscriber_sum, 0)

    frame = Message.encode_request!(conn, command, opts)
    :ok = :gen_tcp.send(conn.socket, frame)

    correlation_sequence = conn.correlation_sequence + correlation_sum
    publisher_sequence = conn.publisher_sequence + publisher_sum
    subscriber_sequence = conn.subscriber_sequence + subscriber_sum

    %{
      conn
      | correlation_sequence: correlation_sequence,
        publisher_sequence: publisher_sequence,
        subscriber_sequence: subscriber_sequence
    }
  end

  def send_response(%Connection{} = conn, command, opts) do
    frame = Message.encode_response!(conn, command, opts)
    :ok = :gen_tcp.send(conn.socket, frame)

    conn
  end
end
