defmodule RabbitMQStream.SuperConsumer do
  defmacro __using__(opts) do
    defaults = Application.get_env(:rabbitmq_stream, :defaults, [])

    serializer = Keyword.get(opts, :serializer, Keyword.get(defaults, :serializer))
    opts = Keyword.put_new(opts, :partitions, Keyword.get(defaults, :partitions, 1))

    quote do
      @opts unquote(opts)
      @behaviour RabbitMQStream.Consumer

      use Supervisor

      def start_link(opts) do
        opts = Keyword.merge(opts, @opts)
        Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @impl true
      def init(opts) do
        {opts, consumer_opts} = Keyword.split(opts, [:super_stream])

        children = [
          {Registry, keys: :unique, name: __MODULE__.Registry},
          {DynamicSupervisor, strategy: :one_for_one, name: __MODULE__.DynamicSupervisor},
          {RabbitMQStream.SuperConsumer.Manager,
           opts ++
             [
               name: __MODULE__.Manager,
               dynamic_supervisor: __MODULE__.DynamicSupervisor,
               registry: __MODULE__.Registry,
               consumer_module: __MODULE__,
               partitions: @opts[:partitions],
               consumer_opts: consumer_opts
             ]}
        ]

        Supervisor.init(children, strategy: :one_for_all)
      end

      unquote(
        if serializer != nil do
          quote do
            def decode!(message), do: unquote(serializer).decode!(message)
          end
        else
          quote do
            def decode!(message), do: message
          end
        end
      )
    end
  end

  defstruct [
    :super_stream,
    :partitions,
    :registry,
    :dynamic_supervisor,
    :consumer_module,
    :consumer_opts
  ]

  @type t :: %__MODULE__{
          super_stream: String.t(),
          partitions: non_neg_integer(),
          dynamic_supervisor: module(),
          consumer_module: module(),
          registry: module(),
          consumer_opts: [RabbitMQStream.Consumer.consumer_option()] | nil
        }

  @type super_consumer_option ::
          {:super_stream, String.t()}
          | {:partitions, non_neg_integer()}
          | RabbitMQStream.Consumer.consumer_option()
end
