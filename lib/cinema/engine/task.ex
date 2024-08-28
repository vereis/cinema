defmodule Cinema.Engine.Task do
  @moduledoc """
  The `Cinema.Engine.Task` module provides a simple implementation of the `Cinema.Engine` behaviour
  which uses the `Task` module to execute projections.

  When in test mode, all Task functions will be executed synchronously. You can enable test mode by calling
  `Cinema.Utils.Task.test_mode(true)` somewhere before executing projections.

  See the `Cinema.Engine` module for more details re: defining engines.
  """

  @behaviour Cinema.Engine

  alias Cinema.Engine
  alias Cinema.Projection
  alias Cinema.Projection.Lens
  alias Cinema.Utils.Task

  @timeout :timer.minutes(1)

  @doc """
  Executes the given `Projection.t()` using the Task engine. Returns `{:ok, projection}` if the projection
  was successfully executed, otherwise returns `{:error, projection}`.

  You can fetch the output of the `Projection.t()` (assuming it was successfully executed) by passing the
  returned `Projection.t()` to `Cinema.Projection.fetch/1` function.

  ## Options

  * `:timeout` - The timeout to use when executing the projection. Defaults to `1 minute`.
  * `:skip_dependencies` - Defaults to `false`. If `true`, skips executing the dependencies of the given projection.
    this is very useful for testing purposes where you use `ExMachina` to "mock" the results of all input projections.

  """
  @impl Cinema.Engine
  def exec(%Projection{} = projection, opts \\ []) do
    timeout = opts[:timeout] || @timeout

    task =
      Task.async(fn ->
        if opts[:skip_dependencies] do
          Engine.do_exec(projection.terminal_projection, projection.lens)
        else
          projection.exec_graph
          |> Enum.map(&List.wrap/1)
          |> Enum.each(fn projections ->
            projections
            |> Enum.map(&Task.async(fn -> Engine.do_exec(&1, projection.lens) end))
            |> Task.await_many(timeout)
          end)
        end

        Lens.apply(projection.lens, projection.terminal_projection, as_stream: true)
      end)

    {:ok, %Projection{projection | meta: %{task: task}}}
  end

  @doc """
  Fetches the output of a `Projection.t()` which has been executed using `Cinema.Engine.exec/2`.
  """
  @impl Cinema.Engine
  def fetch(%Projection{} = projection) do
    case projection.meta[:task] do
      nil ->
        {:error, "The given projection was not executed using the Task engine."}

      task ->
        {:ok, Task.await(task, @timeout)}
    end
  end
end
