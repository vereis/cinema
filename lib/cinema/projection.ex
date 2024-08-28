defmodule Cinema.Projection do
  @moduledoc """
  This module is responsible to defining "projections", which are similar to "views" built into
  most RDBMS systems.

  ## Key Concepts

  A projection is simply a module which tells `Cinema` three things:

  1) What inputs (usually other projections) are required to execute a projection.
  2) What outputs (usually a `Stream`-compatible term) are produced by executing a projection.
  3) Most importantly, the instructions required to derive data for the projection.

  It is important to call out that a `Projection` is different from defining a `View` in a traditional
  RDBMS system. A `View` is a stored query that is executed on-demand, while a `Projection` is a
  series of instructions that can be executed to derive a result, which is optionally stored in a table
  for querying.

  While `View`s can be materialized, at least in PostgreSQL, you're usually forced to refresh the
  entire view whenever you want to update any stored data. `Projection`s on the other hand are designed
  to allow some form of incremental materialization, where only data relevent to the `Cinema.Lens`
  is required to be refreshed.

  Currently, Projections need to be manually called to be refreshed; though future work may include
  automatic triggers for refreshing Projections when their inputs change.

  Please see `Cinema.project/2` for more details on how projections are executed.

  ## Materialized vs Virtual Projections

  Projections currently come in two flavours: virtual and materialized, defaulting to materialized
  for most cases.

  A materialized projection requires users to define an `Ecto.Schema` schema and associated database
  migration to store the projection's output. These projections can then be indexed and queried like any
  other schema.

  Virtual projections on the other hand are not stored in the database, and are instead derived on-the-fly
  by executing the projection's instructions (if any) and immediately returning the Projection's output.

  Generally, virtual projections are used for kickstarting larger `Cinema` data pipelines from
  your application's existing database tables, while materialized projections are used for storing
  intermediate results for later querying.

  You can control whether a projection is materialized or virtual by setting the `:materialized` option
  to `true` or `false` respectively. It is set to `true` by default.

  ## Dematerialization

  Materialized Projections are automatically dematerialized prior to materialization, which means that
  the projection's output is deleted before the projection is executed. This is useful for ensuring that
  the projection's output is always up-to-date, and can be used to ensure that the projection's output
  is idempotent.

  Only data which is in "scope" of a given Projection and Lens is dematerialized, so generally speaking,
  assuming `(dematerialize(input, lens); materialize(input, lens)) == materialize(input, lens)`, you
  don't have to worry about dematerialization causing data loss.

  If you have a projection that is not idempotent, you can disable dematerialization by setting the
  `:dematerialize` option to `false`, though you should be aware that you may want to manually manage
  the projection's output to ensure that it is up-to-date and any outdated data is cleaned up.

  ## Side Effects

  Projections can also, optionally, trigger side-effects by writing to the database or other external
  systems. This can be done by executing the desires side-effect causing code within a Projection's
  `derive/2` callback.

  Generally in such projections, it is inadvisable to dematerialize the projection, as the side-effects
  may not be idempotent, and may rely on the state of the Projection's output as a log of what has
  already been processed.

  If this is the cases, dematerialization can be disabled by setting the `:dematerialize` option to `false`.

  ## Telemetry

  All Projections emit Telemetry events when they are executed, which can be used to monitor said projections.

  The `Cinema` Telemetry events are as follows: TBA
  """

  use Sibyl

  alias Cinema.Projection.Lens
  alias Cinema.Projection.Rank
  alias Cinema.Utils

  # Opts can contain:
  #  - :required - a list of required fields that must be defined in the pattern
  #  - :read_from - the Ecto repo to use for querying, could be `MyApp.Repo`, `MyApp.Repo.replica()`, etc
  #  - :write_to - the Ecto repo to use for writing, could be `MyApp.Repo`, etc
  defmacro __using__(opts \\ []) do
    quote do
      @behaviour unquote(__MODULE__)

      @after_compile unquote(__MODULE__)
      use Ecto.Schema

      import Ecto.Query

      # TODO: use something that gives us queryable functionality

      require unquote(__MODULE__)

      @doc false
      def opts, do: unquote(opts)

      @impl unquote(__MODULE__)
      def derivation({_input, _stream}, _lens) do
        raise ArgumentError, message: "Not Implemented."
      end

      @impl unquote(__MODULE__)
      def fields do
        if unquote(__MODULE__).virtual?(__MODULE__) do
          []
        else
          apply(__MODULE__, :__schema__, [:fields])
        end
      end

      defoverridable derivation: 2
    end
  end

  @type implementation :: module()
  @type input :: implementation()
  @type output :: Ecto.Queryable.t() | [map()] | term()
  @type t :: %__MODULE__{}

  @callback fields() :: [atom()]
  @callback inputs() :: [implementation()]
  @callback output() :: output()

  @callback derivation({input(), output()}, Lens.t()) :: term()

  defstruct [
    :terminal_projection,
    :exec_graph,
    :valid?,
    :engine,
    :read_repo,
    :write_repo,
    meta: %{},
    lens: %Lens{}
  ]

  @doc """
  Builds a new instance of the given projection, with the given lens. Does not execute the projection.
  See `Cinema.Engine` for functions that operate on `Projection.t()`s.

  Takes an optional `lens` argument, which is a `Cinema.Lens.t()` struct that can be used to
  scope the projection's inputs and outputs.

  Also takes an optional `opts` argument, which is a `Keyword.t()` list of options that can be used to
  configure the projection's behavior.

  ## Options

  * `:application` - The application to use when fetching the list of all projections. Defaults to `nil`.

  """
  @spec build!(implementation, Lens.t(), Keyword.t()) :: t()
  def build!(projection, lens \\ %Lens{}, opts \\ []) do
    unless implemented?(projection) do
      raise ArgumentError,
        message: """
        The given projection does not implement the `Cinema.Projection` behaviour.
        """
    end

    application = opts[:application]
    opts = projection.opts()

    write_repo = opts[:write_repo] || opts[:repo]
    read_repo = opts[:read_repo] || write_repo

    %__MODULE__{
      lens: lens,
      terminal_projection: projection,
      write_repo: write_repo,
      read_repo: read_repo,
      exec_graph: dependencies(application, projection)
    }
  end

  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: term()
  def __after_compile__(env, _bytecode) do
    implementation = env.module

    unless virtual?(implementation) do
      required_keys = MapSet.new(implementation.opts[:required] || [])
      defined_keys = implementation |> struct([]) |> Map.keys() |> MapSet.new()

      # TODO: implement custom exception
      unless MapSet.subset?(required_keys, defined_keys) do
        raise ArgumentError,
          message: """
          `#{inspect(__MODULE__)}`s has been configured to required the following fields: `#{inspect(MapSet.to_list(required_keys))}`
          """
      end
    end
  end

  @spec materialize(rows_or_queryable :: term()) :: term()
  defmacro materialize(rows_or_queryable) do
    caller = __CALLER__.module
    {function, arity} = __CALLER__.function

    # TODO: custom exception
    unless function == :derivation && arity == 2 do
      raise ArgumentError,
        message: """
        `#{inspect(__MODULE__)}.materialize/1` can only be called from within a `#{__MODULE__}`'s `derivation/2` callback.
        """
    end

    quote bind_quoted: [caller: caller, rows_or_queryable: rows_or_queryable] do
      opts = __MODULE__.opts()
      fields = __MODULE__.fields()

      write_repo = opts[:write_repo] || opts[:repo]
      read_repo = opts[:read_repo] || write_repo

      {_count, rows} =
        cond do
          is_list(rows_or_queryable) ->
            rows_or_queryable
            |> Enum.map(&Map.take(&1, fields))
            |> then(&write_repo.insert_all(caller, &1, opts))

          is_struct(rows_or_queryable, Ecto.Query) and read_repo != write_repo ->
            # TODO: utilize sentinel values to avoid re-inserting the same data over and over
            rows =
              rows_or_queryable |> read_repo.all(opts) |> Enum.map(&Utils.sanitize_timestamps/1)

            postgres_max_parameters = 65_535
            paramters_per_row = rows |> List.first(%{}) |> map_size() |> max(1)
            max_rows_per_batch = (postgres_max_parameters / paramters_per_row) |> floor() |> max(1)

            rows
            |> Enum.chunk_every(max_rows_per_batch)
            |> Enum.reduce({0, []}, fn batch, {count, acc} ->
              {count_inc, acc_inc} = write_repo.insert_all(caller, batch, opts)
              {count + count_inc, (acc || []) ++ rows}
            end)

          is_struct(rows_or_queryable, Ecto.Query) and read_repo == write_repo ->
            write_repo.insert_all(caller, rows_or_queryable, opts)
        end

      rows
    end
  end

  @spec dematerialize(Lens.t()) :: term()
  defmacro dematerialize(lens) do
    caller = __CALLER__.module
    {function, arity} = __CALLER__.function

    # TODO: custom exception
    unless function == :derivation && arity == 2 do
      raise ArgumentError,
        message: """
        `#{inspect(__MODULE__)}.dematerialize/1` can only be called from within a `#{__MODULE__}`'s `derivation/2` callback.
        """
    end

    quote bind_quoted: [caller: caller, lens: lens] do
      opts = caller.opts()
      write_repo = opts[:write_repo] || opts[:repo]

      unless is_struct(lens, Lens) do
        raise ArgumentError,
          message: """
          `#{inspect(__MODULE__)}.dematerialize/1` expects an argument of type `Cinema.Lens.t()`.
          """
      end

      unless Keyword.get(caller.opts(), :dematerialize, true) do
        raise ArgumentError,
          message: """
          `#{inspect(__MODULE__)}` has not been configured to be dematerialized.
          """
      end

      __MODULE__
      |> Ecto.Query.where(^lens.filters)
      |> write_repo.delete_all()
    end
  end

  @doc """
  Returns `true` if the given module is a virtual projection (does not define a schema), otherwise returns `false`.

  See examples:

    ```elixir
    iex> Cinema.Projection.virtual?(Enum)
    false

    iex> defmodule MyApp.VirtualProjection do
    ...>   use Cinema.Projection
    ...>
    ...>   @impl Cinema.Projection
    ...>   def inputs, do: []
    ...>
    ...>   @impl Cinema.Projection
    ...>   def ouput, do: []
    ...> end
    iex> Cinema.Projection.virtual?(MyApp.VirtualProjection)
    true
    ```
  """
  @spec virtual?(implementation :: module()) :: boolean()
  def virtual?(implementation) do
    implemented?(implementation) and not function_exported?(implementation, :__schema__, 1)
  end

  @doc """
  Returns `true` if the given module implements the `#{__MODULE__}` behaviour, otherwise returns `false`.

  See examples:

    ```elixir
    iex> Cinema.Projection.implemented?(Enum)
    false

    iex> defmodule MyApp.SomeProjection do
    ...>   use Cinema.Projection
    ...>
    ...>   @impl Cinema.Projection
    ...>   def inputs, do: []
    ...>
    ...>   @impl Cinema.Projection
    ...>   def ouput, do: []
    ...> end
    iex> Cinema.Projection.implemented?(MyApp.SomeProjection)
    true
    ```
  """
  @spec implemented?(module()) :: boolean()
  def implemented?(module) do
    Utils.implemented?(module, __MODULE__)
  end

  @doc "Lists all defined projections defined in the given application or loaded in the VM."
  @spec list(application :: atom() | nil) :: [module()]
  def list(application \\ nil) do
    static_modules =
      case :application.get_key(application, :modules) do
        {:ok, static_modules} ->
          static_modules

        _otherwise ->
          []
      end

    dynamic_modules =
      :code.all_loaded() |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 in static_modules))

    for module <- static_modules ++ dynamic_modules,
        match?({:module, _module}, :code.ensure_loaded(module)),
        implemented?(module) do
      module
    end
  end

  @doc "Returns the dependency graph needed to execute the given projection."
  @spec dependencies(module()) :: [module()]
  @spec dependencies(application :: atom(), module()) :: [module()]
  def dependencies(application \\ nil, implementation) do
    application
    |> list()
    |> Enum.map(&{&1, &1.inputs()})
    |> Rank.derive!(implementation)
  end
end
