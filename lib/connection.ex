defmodule RabbitStream.Connection do
  use GenServer
  require Logger

  alias __MODULE__, as: Connection

  alias RabbitStream.Message
  alias RabbitStream.Message.{Request, Response}

  alias RabbitStream.Message.Command.{
    SaslHandshake,
    PeerProperties,
    SaslAuthenticate,
    Close,
    Tune,
    Open,
    Heartbeat,
    Create,
    Delete,
    StoreOffset,
    QueryOffset,
    DeclarePublisher,
    DeletePublisher,
    MetadataUpdate
  }

  alias Message.Code.{
    Ok,
    SaslMechanismNotSupported,
    AuthenticationFailure,
    SaslError,
    SaslChallenge,
    SaslAuthenticationFailureLoopback,
    VirtualHostAccessFailure
  }

  defstruct [
    :host,
    :vhost,
    :port,
    :username,
    :password,
    :socket,
    frame_max: 1_048_576,
    heartbeat: 60,
    version: 1,
    state: "closed",
    peer_properties: [],
    connection_properties: [],
    mechanisms: [],
    connect_request: nil,
    requests: %{},
    correlation_sequence: 1,
    publisher_sequence: 1,
    subscription_sequence: 1
  ]

  # @states [
  #   "connecting",
  #   "closed",
  #   "closing",
  #   "open",
  #   "opening"
  # ]

  def start_link(default \\ []) when is_list(default) do
    GenServer.start_link(__MODULE__, default)
  end

  def connect(pid) do
    GenServer.call(pid, {:connect})
  end

  def close(pid, reason \\ "", code \\ 0x00) do
    GenServer.call(pid, {:close, reason, code})
  end

  def create_stream(pid, name, opts \\ []) when is_binary(name) do
    GenServer.call(pid, {:create, name, opts})
  end

  def delete_stream(pid, name) when is_binary(name) do
    GenServer.call(pid, {:delete, name})
  end

  def store_offset(pid, stream_name, offset_reference, offset)
      when is_binary(stream_name)
      when is_binary(offset_reference)
      when is_integer(offset)
      when length(stream_name) <= 255 do
    GenServer.call(pid, {:store_offset, stream_name: stream_name, offset_reference: offset_reference, offset: offset})
  end

  def query_offset(pid, stream_name, offset_reference)
      when is_binary(stream_name)
      when is_binary(offset_reference) do
    GenServer.call(pid, {:query_offset, stream_name: stream_name, offset_reference: offset_reference})
  end

  def declare_publisher(pid, stream_name, publisher_reference)
      when is_binary(publisher_reference)
      when is_binary(stream_name)
      when length(stream_name) <= 255 do
    GenServer.call(pid, {:declare_publisher, stream_name: stream_name, publisher_reference: publisher_reference})
  end

  def delete_publisher(pid, id)
      when is_integer(id)
      when id <= 255 do
    GenServer.call(pid, {:delete_publisher, id: id})
  end

  def get_state(pid) do
    GenServer.call(pid, {:get_state})
  end

  @impl true
  def init(opts \\ []) do
    username = opts[:username] || "guest"
    password = opts[:password] || "guest"
    host = opts[:host] || "localhost"
    port = opts[:port] || 5552
    vhost = opts[:vhost] || "/"

    conn = %Connection{
      host: host,
      port: port,
      vhost: vhost,
      username: username,
      password: password
    }

    {:ok, conn}
  end

  @impl true
  def handle_call({:get_state}, _from, %Connection{} = conn) do
    {:reply, conn, conn}
  end

  def handle_call({:connect}, from, %Connection{state: "closed"} = conn) do
    Logger.info("Connecting to server: #{conn.host}:#{conn.port}")

    with {:ok, socket} <- :gen_tcp.connect(String.to_charlist(conn.host), conn.port, [:binary, active: true]),
         :ok <- :gen_tcp.controlling_process(socket, self()) do
      Logger.debug("Connection stablished. Initiating properties exchange.")

      conn =
        %{conn | socket: socket, state: "connecting", connect_request: from}
        |> send_request(%PeerProperties{})

      {:noreply, conn}
    else
      err ->
        Logger.error("Failed to connect to #{conn.host}:#{conn.port}")
        {:reply, {:error, err}, conn}
    end
  end

  def handle_call({:connect}, _from, %Connection{} = conn) do
    {:reply, {:error, "Can only connect while in the \"closed\" state. Current state: \"#{conn.state}\""}, conn}
  end

  def handle_call(_, _from, %Connection{state: "closed"} = conn) do
    {:reply, {:error, :closed}, conn}
  end

  def handle_call({:close, reason, code}, from, %Connection{} = conn) do
    Logger.info("Connection close requested by client: #{reason} #{code}")

    conn =
      %{conn | state: "closing"}
      |> push_tracker(%Close{}, from)
      |> send_request(%Close{}, reason: reason, code: code)

    {:noreply, conn}
  end

  def handle_call({:create, name, opts}, from, %Connection{} = conn) do
    conn =
      conn
      |> push_tracker(%Create{}, from)
      |> send_request(%Create{}, name: name, arguments: opts)

    {:noreply, conn}
  end

  def handle_call({:delete, name}, from, %Connection{} = conn) do
    conn =
      conn
      |> push_tracker(%Delete{}, from)
      |> send_request(%Delete{}, name: name)

    {:noreply, conn}
  end

  def handle_call({:store_offset, opts}, _from, %Connection{} = conn) do
    conn =
      conn
      |> send_request(%StoreOffset{}, opts)

    {:reply, :ok, conn}
  end

  def handle_call({:query_offset, opts}, from, %Connection{} = conn) do
    conn =
      conn
      |> push_tracker(%QueryOffset{}, from)
      |> send_request(%QueryOffset{}, opts)

    {:noreply, conn}
  end

  def handle_call({:declare_publisher, opts}, from, %Connection{} = conn) do
    conn =
      conn
      |> push_tracker(%DeclarePublisher{}, from, conn.publisher_sequence)
      |> send_request(%DeclarePublisher{}, opts ++ [publisher_sum: 1])

    {:noreply, conn}
  end

  def handle_call({:delete_publisher, opts}, from, %Connection{} = conn) do
    conn =
      conn
      |> push_tracker(%DeletePublisher{}, from)
      |> send_request(%DeletePublisher{}, opts)

    {:noreply, conn}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, conn) do
    conn =
      data
      |> Message.decode!()
      |> Enum.reduce(conn, fn
        %Request{} = decoded, conn ->
          handle_message(conn, decoded)

        %Response{code: %Ok{}} = decoded, conn ->
          handle_message(conn, decoded)

        decoded, conn ->
          handle_error(conn, decoded)
      end)

    case conn.state do
      "closed" ->
        {:noreply, conn, :hibernate}

      _ ->
        {:noreply, conn}
    end
  end

  def handle_info({:heartbeat}, conn) do
    conn = send_request(conn, %Heartbeat{}, correlation_sum: 0)

    Process.send_after(self(), {:heartbeat}, conn.heartbeat * 1000)

    {:noreply, conn}
  end

  def handle_info({:tcp_closed, _socket}, conn) do
    if conn.state == "connecting" do
      Logger.warn(
        "The connection was closed by the host, after the socket was already open, while running the authentication sequence. This could be caused by the server not having Stream Plugin active"
      )
    end

    conn = %{conn | socket: nil, state: "closed"} |> handle_closed(:tcp_closed)

    {:noreply, conn, :hibernate}
  end

  def handle_info({:tcp_error, _socket, reason}, conn) do
    conn = %{conn | socket: nil, state: "closed"} |> handle_closed(reason)

    {:noreply, conn}
  end

  defp handle_message(%Connection{} = conn, %Response{command: %Close{}} = response) do
    Logger.debug("Connection closed: #{conn.host}:#{conn.port}")

    {{pid, _data}, conn} = pop_tracker(conn, %Close{}, response.correlation_id)

    conn = %{conn | state: "closed", socket: nil}

    GenServer.reply(pid, :ok)

    conn
  end

  defp handle_message(%Connection{} = conn, %Request{command: %Close{}} = request) do
    Logger.debug("Connection close requested by server: #{request.data.code} #{request.data.reason}")
    Logger.debug("Connection closed")

    %{conn | state: "closing"}
    |> send_response(:close, correlation_id: request.correlation_id, code: %Ok{})
    |> handle_closed(request.data.reason)
  end

  defp handle_message(%Connection{state: "closed"} = conn, _) do
    Logger.error("Message received on a closed connection")

    conn
  end

  defp handle_message(%Connection{} = conn, %Response{command: %PeerProperties{}} = request) do
    Logger.debug("Exchange successful.")
    Logger.debug("Initiating SASL handshake.")

    %{conn | peer_properties: request.data.peer_properties}
    |> send_request(%SaslHandshake{})
  end

  defp handle_message(%Connection{} = conn, %Response{command: %SaslHandshake{}} = request) do
    Logger.debug("SASL handshake successful. Initiating authentication.")

    %{conn | mechanisms: request.data.mechanisms}
    |> send_request(%SaslAuthenticate{})
  end

  defp handle_message(%Connection{} = conn, %Response{command: %SaslAuthenticate{}, data: %{sasl_opaque_data: ""}}) do
    Logger.debug("Authentication successful. Initiating connection tuning.")

    conn
  end

  defp handle_message(%Connection{} = conn, %Response{command: %SaslAuthenticate{}}) do
    Logger.debug("Authentication successful. Skipping connection tuning.")
    Logger.debug("Opening connection to vhost: \"#{conn.vhost}\"")

    conn
    |> send_request(%Open{})
    |> Map.put(:state, "opening")
  end

  defp handle_message(%Connection{} = conn, %Response{command: %Tune{}} = response) do
    Logger.debug("Tunning complete. Starting heartbeat timer.")

    Process.send_after(self(), {:heartbeat}, conn.heartbeat * 1000)

    %{conn | frame_max: response.data.frame_max, heartbeat: response.data.heartbeat}
  end

  defp handle_message(%Connection{} = conn, %Request{command: %Tune{}} = request) do
    Logger.debug("Tunning data received. Starting heartbeat timer.")
    Logger.debug("Opening connection to vhost: \"#{conn.vhost}\"")

    %{conn | frame_max: request.data.frame_max, heartbeat: request.data.heartbeat}
    |> send_response(:tune, correlation_id: request.correlation_id)
    |> Map.put(:state, "opening")
    |> send_request(%Open{})
  end

  defp handle_message(%Connection{} = conn, %Response{command: %Open{}} = response) do
    Logger.debug("Successfully opened connection with vhost: \"#{conn.vhost}\"")

    client = conn.connect_request

    conn = %{conn | state: "open", connect_request: nil, connection_properties: response.data.connection_properties}

    GenServer.reply(client, :ok)

    conn
  end

  defp handle_message(%Connection{} = conn, %Request{command: %Heartbeat{}}) do
    conn
  end

  defp handle_message(%Connection{} = conn, %Request{command: %MetadataUpdate{}} = request) do
    Logger.info("Metadata update request received for stream  \"#{request.data.stream_name}\"")

    conn
  end

  defp handle_message(%Connection{} = conn, %Response{command: %QueryOffset{}} = response) do
    {{pid, _data}, conn} = pop_tracker(conn, %QueryOffset{}, response.correlation_id)

    if pid != nil do
      GenServer.reply(pid, {:ok, response.data.offset})
    end

    conn
  end

  defp handle_message(%Connection{} = conn, %Response{command: %DeclarePublisher{}} = response) do
    {{pid, id}, conn} = pop_tracker(conn, %DeclarePublisher{}, response.correlation_id)

    if pid != nil do
      GenServer.reply(pid, {:ok, id})
    end

    conn
  end

  defp handle_message(%Connection{} = conn, %Response{command: command} = response)
       when command in [%Create{}, %Delete{}, %DeletePublisher{}] do
    {{pid, _data}, conn} = pop_tracker(conn, command, response.correlation_id)

    if pid != nil do
      GenServer.reply(pid, :ok)
    end

    conn
  end

  defp handle_error(%Connection{} = conn, %Response{code: code})
       when code in [
              %SaslMechanismNotSupported{},
              %AuthenticationFailure{},
              %SaslError{},
              %SaslChallenge{},
              %SaslAuthenticationFailureLoopback{},
              %VirtualHostAccessFailure{}
            ] do
    Logger.error("Failed to connect to #{conn.host}:#{conn.port}. Reason: #{code.__struct__}")

    GenServer.reply(conn.connect_request, {:error, code})

    %{conn | state: "closed", socket: nil, connect_request: nil}
  end

  defp handle_error(%Connection{} = conn, %Response{command: command} = response)
       when command in [
              %Create{},
              %Delete{},
              %QueryOffset{},
              %DeclarePublisher{},
              %DeletePublisher{}
            ] do
    {{pid, _data}, conn} = pop_tracker(conn, command, response.correlation_id)

    if pid != nil do
      GenServer.reply(pid, {:error, response.code})
    end

    conn
  end

  defp handle_closed(%Connection{} = conn, reason) do
    for client <- Map.values(conn.requests) do
      GenServer.reply(client, {:error, reason})
    end

    %{conn | requests: %{}}
  end

  defp send_request(%Connection{} = conn, command, opts \\ []) do
    {correlation_sum, opts} = Keyword.pop(opts, :correlation_sum, 1)
    {publisher_sum, opts} = Keyword.pop(opts, :publisher_sum, 0)

    frame = Request.new_encoded!(conn, command, opts)
    :ok = :gen_tcp.send(conn.socket, frame)

    correlation_sequence = conn.correlation_sequence + correlation_sum
    publisher_sequence = conn.publisher_sequence + publisher_sum

    %{conn | correlation_sequence: correlation_sequence, publisher_sequence: publisher_sequence}
  end

  defp send_response(%Connection{} = conn, command, opts) do
    frame = Response.new_encoded!(conn, command, opts)
    :ok = :gen_tcp.send(conn.socket, frame)

    conn
  end

  defp push_tracker(%Connection{} = conn, type, from, data \\ nil) when is_struct(type) when is_pid(from) do
    requests = Map.put(conn.requests, {type, conn.correlation_sequence}, {from, data})

    %{conn | requests: requests}
  end

  defp pop_tracker(%Connection{} = conn, type, correlation) when is_struct(type) do
    {entry, requests} = Map.pop(conn.requests, {type, correlation})

    {pid, _data} = entry

    if pid == nil do
      Logger.error("No pending request for \"#{type}:#{correlation}\" found.")
    end

    {entry, %{conn | requests: requests}}
  end
end
