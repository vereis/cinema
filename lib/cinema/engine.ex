defmodule Cinema.Engine do
  @moduledoc """
  The `Cinema.Engine` module provides a behaviour for defining engines which can execute projections
  defined using the `Cinema.Projection` module.

  See the `Cinema.Engine.Task` module for an example implementation of this behaviour.
  Also see the `Cinema.Projection` module for more details re: defining projections.
  """

  alias Cinema.Engine.Task
  alias Cinema.Projection
  alias Cinema.Projection.Lens
  alias Cinema.Utils

  @callback exec(Projection.t()) :: {:ok, Projection.t()} | {:error, Projection.t()}
  @callback fetch(Projection.t()) :: term()

  defdelegate test_mode?(), to: Utils.Task
  defdelegate test_mode(bool), to: Utils.Task

  @doc """
  Returns `true` if the given module implements the `#{__MODULE__}` behaviour, otherwise returns `false`.

  See examples:

    ```elixir
    iex> Cinema.Engine.implemented?(Enum)
    false
    iex> Cinema.Projection.implemented?(Cinema.Engine.Task)
    true
    ```
  """
  @spec implemented?(module()) :: boolean()
  def implemented?(module) do
    Utils.implemented?(module, __MODULE__)
  end

  @doc """
  Executes the given `Projection.t()` using the given engine. Returns `{:ok, projection}` if the projection
  was successfully executed, otherwise returns `{:error, projection}`.

  You can fetch the output of the `Projection.t()` (assuming it was successfully executed) by passing the
  returned `Projection.t()` to `Cinema.Projection.fetch/1` function.
  """
  @spec exec(Projection.t(), Keyword.t()) ::
          {:ok, Projection.t()} | {:error, Projection.t()}
  def exec(%Projection{} = projection, opts \\ [engine: Task]) do
    engine = opts[:engine] || Task

    unless implemented?(engine) do
      raise ArgumentError,
        message: "Engine `#{inspect(engine)}` does not implement the `#{__MODULE__}` behaviour."
    end

    with {status, %Projection{} = projection} <- engine.exec(projection, opts) do
      {status, %Projection{projection | engine: engine, valid?: status == :ok}}
    end
  end

  @doc """
  Fetches the output of a `Projection.t()` which has been executed using `Cinema.Engine.exec/2`.
  """
  @spec fetch(Projection.t()) :: {:ok, term()} | {:error, String.t()}
  def fetch(%Projection{} = projection) when projection.valid? and is_atom(projection.engine) do
    projection.engine.fetch(projection)
  end

  def fetch(%Projection{} = _projection) do
    {:error, "Projection is not valid."}
  end

  @doc false
  @spec do_exec(module(), Lens.t()) :: :ok
  def do_exec(projection, %Lens{} = lens) do
    opts = projection.opts()
    timeout = opts[:timeout] || :timer.minutes(1)
    write_repo = opts[:write_repo] || opts[:repo]
    read_repo = opts[:read_repo] || write_repo

    closure = fn ->
      Enum.each(
        projection.inputs(),
        &projection.derivation({&1, Lens.apply(lens, &1, as_stream: true)}, lens)
      )
    end

    {:ok, _resp} =
      if write_repo != read_repo do
        write_repo.transaction(
          fn ->
            read_repo.transaction(closure, timeout: timeout)
          end,
          timeout: timeout
        )
      else
        write_repo.transaction(closure, timeout: timeout)
      end

    :ok
  end
end
