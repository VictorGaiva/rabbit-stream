defmodule RabbitStream.Publisher do
  use GenServer

  alias RabbitStream.Connection

  alias __MODULE__

  defstruct [
    :publishing_id,
    :reference_name,
    :connection,
    :stream_name,
    :sequence,
    :id
  ]

  def get_state(pid) do
    GenServer.call(pid, {:get_state})
  end

  def start_link(args, opts \\ []) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  ## Callbacks
  @impl true
  def init(opts) do
    reference_name = opts[:reference_name] || Atom.to_string(__MODULE__)
    connection = opts[:connection]
    stream_name = opts[:stream_name]

    with :ok <- Connection.connect(connection),
         {:ok, id} <- Connection.declare_publisher(connection, stream_name, reference_name),
         {:ok, sequence} <- Connection.query_publisher_sequence(connection, stream_name, reference_name) do
      state = %Publisher{
        id: id,
        stream_name: stream_name,
        connection: connection,
        reference_name: reference_name,
        sequence: sequence
      }

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:get_state}, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def terminate(_reason, state) do
    Connection.delete_publisher(state.connection, state.id)
  end
end
