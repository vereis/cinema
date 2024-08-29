defmodule Cinema do
  @moduledoc File.read!("README.md")

  alias Cinema.Engine
  alias Cinema.Projection
  alias Cinema.Projection.Lens

  require Logger

  @doc """
  Projects a module that implements the `Cinema.Projection` behaviour.

  Projection is done by reflecting on the given projection and building a dependency graph of all of it's inputs,
  which is then executed in the correct order.

  The output of each dependency projection is streamed into the given projection's `c:Cinema.Projection.derivation/2`
  callback. This callback is responsible for materializing database table rows which can then be returned as the final
  output of the projection.

  Optionally takes a `Lens.t()` or a `Keyword.t()` filter list to apply to the projection.

  Additionally, you can pass in a `Keyword.t()` list of options to control the behavior of how the projection is
  executed.

  Note that by default, the given projection's final `c:Cinema.Projection.output/0` will be awaited and
  evaluated by the projection's configured `read_repo`. If you want to control the execute the projection, pass
  `async: true` as an option.

  ## Options

  * `:async` - Defaults to `false`. If `true`, the projection will be executed immediately but the given projection's
    final output will not be awaited and returned. Instead, the projection itself will be returned.

    You can then await and fetch the final output via `Cinema.fetch/1`.

  * `:engine` - The engine to use to execute the projection. Defaults to `Cinema.Engine.Task`. See
    `Cinema.Engine` for more information.

  * `:timeout` - The timeout to use when executing the projection. Defaults to `1 minute`.

  * `:allow_empty_filters` - Defaults to `false`. If `true`, skips the warning message that gets logged when an empty
    filter list is provided.

  Options are additionally also passed to the engine that is used to execute the projection, as well as used when
  building the projection itself.
  """
  @spec project(Projection.t()) :: {:ok, [term()]} | {:error, term()}
  @spec project(Projection.t(), Lens.t()) :: {:ok, [term()]} | {:error, term()}
  @spec project(Projection.t(), Lens.t(), Keyword.t()) ::
          {:ok, Projection.t() | [term()]} | {:error, term()}
  def project(projection, lens \\ %Lens{}, opts \\ [])

  def project(projection, filters, opts) when is_list(filters) do
    filters
    |> Lens.build!()
    |> then(&project(projection, &1, opts))
  end

  def project(projection, %Lens{} = lens, opts) do
    unless Projection.implemented?(projection) do
      raise ArgumentError,
        message: """
        `Cinema.project/2` expects a `Cinema.Projection` as its first argument, got `#{inspect(projection)}`.
        """
    end

    if lens.filters == [] and !opts[:allow_empty_filters] do
      Logger.warning("""
      `Cinema.project/2` was called with an empty filter list. When this happens, all
      neccessary projections will be projected and run without any filters and scoping applied.

      If you want to allow this behavior, pass `allow_empty_filters: true` as an option to `Cinema.project/3`.
      """)
    end

    {:ok, %Projection{} = projection} =
      projection
      |> Projection.build!(lens, opts)
      |> Engine.exec(opts)

    (opts[:async] && {:ok, projection}) ||
      projection.read_repo.transaction(
        fn ->
          {:ok, value} = Engine.fetch(projection)
          Enum.to_list(value)
        end,
        timeout: opts[:timeout] || :timer.minutes(1)
      )
  end

  defdelegate fetch(projection), to: Engine
end
