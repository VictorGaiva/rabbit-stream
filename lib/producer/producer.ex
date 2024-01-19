defmodule RabbitMQStream.Producer do
  @moduledoc """
  `RabbitMQStream.Producer` allows you to define modules or processes that publish messages to a single stream.

  # Defining a producer Module

  A standalone producer module can be defined with:

      defmodule MyApp.MyProducer do
        use RabbitMQStream.Producer,
          stream_name: "my-stream",
          connection: MyApp.MyConnection
      end

  After adding it to your supervision tree, you can publish messages with:

      MyApp.MyProducer.publish("Hello, world!")

  You can add the producer to your supervision tree as follows this:

      def start(_, _) do
        children = [
          # ...
          MyApp.MyProducer
        ]

        opts = # ...
        Supervisor.start_link(children, opts)
      end

  The standalone producer starts its own `RabbitMQStream.Connection`, declaring itself and fetching its most recent `publishing_id`, and declaring the stream, if it does not exist.

  # Configuration
  The RabbitMQStream.Producer accepts the following options:

  * `:stream_name` - The name of the stream to publish to. Required.
  * `:reference_name` - The string which is used by the server to prevent [Duplicate Message](https://blog.rabbitmq.com/posts/2021/07/rabbitmq-streams-message-deduplication/). Defaults to `__MODULE__.Producer`.
  * `:connection` - The identifier for a `RabbitMQStream.Connection`.
  * `:serializer` - The module to use to decode the message. Defaults to `nil`, which means no encoding is done.

  You can also declare the configuration in your `config.exs`:

      config :rabbitmq_stream, MyApp.MyProducer,
        stream_name: "my-stream",
        connection: MyApp.MyConnection


  # Setting up

  You can optionally define a `before_start/2` callback to perform setup logic, such as creating the stream, if it doesn't yet exists.

      defmodule MyApp.MyProducer do
        use RabbitMQStream.Producer,
          stream_name: "my-stream",
          connection: MyApp.MyConnection

        @impl true
        def before_start(_opts, state) do
          # Create the stream
          RabbitMQStream.Connection.create_stream(state.connection, state.stream_name)

          state
        end
      end

  # Configuration

    You can configure each Producer with:

        config :rabbitmq_stream, MyApp.MyProducer,
          stream_name: "my-stream",
          connection: MyApp.MyConnection

    And also you can override the defaults of all producers with:

          config :rabbitmq_stream, :defaults,
            producer: [
              connection: MyApp.MyConnection,
              # ...
            ]
            serializer: Jason

    Globally configuring all producers ignores the following options:

      * `:stream_name`
      * `:reference_name`

  """

  defmacro __using__(opts) do
    defaults = Application.get_env(:rabbitmq_stream, :defaults, [])

    serializer = Keyword.get(opts, :serializer, Keyword.get(defaults, :serializer))

    quote location: :keep do
      @opts unquote(opts)
      require Logger

      @behaviour RabbitMQStream.Producer

      def start_link(opts \\ []) do
        unless !Keyword.has_key?(opts, :serializer) do
          Logger.warning("You can only pass `:serializer` option to compile-time options.")
        end

        opts =
          Application.get_env(:rabbitmq_stream, __MODULE__, [])
          |> Keyword.merge(@opts)
          |> Keyword.merge(opts)
          |> Keyword.put_new(:producer_module, __MODULE__)
          |> Keyword.put(:name, __MODULE__)

        RabbitMQStream.Producer.start_link(opts)
      end

      def child_spec(opts) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
      end

      def publish(message) do
        value = filter_value(message)

        message = encode!(message)

        GenServer.cast(__MODULE__, {:publish, {message, value}})
      end

      def before_start(_opts, state), do: state
      def filter_value(_), do: nil

      unquote(
        # We need this piece of logic so we can garantee that the 'encode!/1' call is executed
        # by the caller process, not the Producer process itself.
        if serializer != nil do
          quote do
            def encode!(message), do: unquote(serializer).encode!(message)
          end
        else
          quote do
            def encode!(message), do: message
          end
        end
      )

      defoverridable RabbitMQStream.Producer
    end
  end

  def start_link(opts \\ []) do
    opts =
      Application.get_env(:rabbitmq_stream, :defaults, [])
      |> Keyword.get(:producer, [])
      |> Keyword.drop([:stream_name, :offset_reference, :private])
      |> Keyword.merge(opts)

    GenServer.start_link(RabbitMQStream.Producer.LifeCycle, opts, name: opts[:name])
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  defstruct [
    :publishing_id,
    :reference_name,
    :connection,
    :stream_name,
    :sequence,
    :producer_module,
    :id
  ]

  @type t :: %__MODULE__{
          publishing_id: String.t(),
          reference_name: String.t(),
          connection: GenServer.server(),
          stream_name: String.t(),
          sequence: non_neg_integer() | nil,
          id: String.t() | nil,
          producer_module: module()
        }

  @type options :: [option()]

  @type option ::
          {:stream_name, String.t()}
          | {:reference_name, String.t()}
          | {:connection, GenServer.server()}
  @optional_callbacks [before_start: 2, filter_value: 1]

  @doc """
  Optional callback that is called after the process has started, but before the
  producer has declared itself and fetched its most recent `publishing_id`.

  This is usefull for setup logic, such as creating the Stream, if it doesn't yet exists.
  """
  @callback before_start(options(), t()) :: t()

  @doc """
  Callback used to fetch the filter value for a message

  Example:
        @impl true
        def filter_value(message) do
          message["key"]
        end
  """
  @callback filter_value(term()) :: String.t()
end
