if Code.ensure_loaded?(Oban.Pro.Workflow) do
  defmodule Cinema.Engine.Oban.Pro.Workflow do
    @moduledoc """
    The `Cinema.Engine.Oban.Pro.Workflow` module provides an implementation of the `Cinema.Engine` behaviour
    which uses the `Oban.Pro.Workflow` module to execute projections.

    See `Oban.Testing` for testing information.

    See the `Cinema.Engine` module for more details re: defining engines.
    """

    @behaviour Cinema.Engine

    alias Cinema.Engine
    alias Cinema.Projection
    alias Cinema.Projection.Lens
    alias Oban.Pro.Workflow

    defmodule Worker do
      @moduledoc false
      use Oban.Pro.Worker, queue: :default

      alias Cinema.Engine
      alias Cinema.Projection

      @impl Oban.Pro.Worker
      def process(%{args: %{"projection" => encoded_projection, "lens" => encoded_lens}}) do
        lens = encoded_lens |> Base.decode64!() |> :erlang.binary_to_term()
        projection = encoded_projection |> Base.decode64!() |> :erlang.binary_to_term()

        :ok = Engine.do_exec(projection, lens)
      end
    end

    # TODO: support custom timeouts
    # @timeout :timer.minutes(1)

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
      # TODO: support custom timeouts
      # timeout = opts[:timeout] || @timeout
      priority = opts[:priority] || nil
      queue = opts[:queue] || :default
      oban = opts[:oban] || Oban

      # Mainly for testing purposes, you can set `relative_to` to offset all time calculations
      # to fall relative to a certain date or datetime.
      #
      # Can also be used to schedule a job that failed for a previous day, if that happens for
      # some reason.
      relative_to = Keyword.get(opts, :relative_to, DateTime.utc_now())

      # If `immediately: false`, then we schedule the job for 00:00 UTC, which is also the default.
      # Pass `immediately: true` to schedule the job for the current time.

      scheduled_at =
        if Keyword.get(opts, :immediately) do
          relative_to
        else
          %{relative_to | hour: 1, minute: 0, second: 0, microsecond: 0}
        end

      encoded_lens = projection.lens |> :erlang.term_to_binary() |> Base.encode64()

      normalized_exec_graph =
        Enum.map(projection.exec_graph, &List.wrap/1)

      workflow_dependencies =
        Enum.zip(normalized_exec_graph, [[] | normalized_exec_graph])

      workflow =
        Enum.reduce(workflow_dependencies, Workflow.new(), fn {projections, deps}, workflow ->
          Enum.reduce(projections, workflow, fn projection, workflow ->
            encoded_projection = projection |> :erlang.term_to_binary() |> Base.encode64()

            Workflow.add(
              workflow,
              projection,
              Worker.new(%{projection: encoded_projection, lens: encoded_lens},
                scheduled_at: scheduled_at,
                priority: priority,
                queue: queue
              ),
              deps: deps
            )
          end)
        end)

      %Oban.Job{} =
        job =
        workflow
        |> Oban.insert_all()
        |> List.first()
        |> Map.get(:meta, %{})
        |> Map.get("workflow_id")
        |> then(&Workflow.get_job(oban, &1, projection.terminal_projection))

      {:ok, %Projection{projection | meta: %{job: job}}}
    end

    @doc """
    Fetches the output of a `Projection.t()` which has been executed using `Cinema.Engine.exec/2`.
    """
    @impl Cinema.Engine
    def fetch(%Projection{} = projection) do
      case projection.meta[:job] do
        nil ->
          {:error, "The given projection was not executed using the `#{__MODULE__}` engine."}

        job ->
          job = projection.read_repo.reload!(job, force: true)

          cond do
            job.state == "completed" ->
              {:ok, Lens.apply(projection.lens, projection.terminal_projection, as_stream: true)}

            job.state in ["ready", "scheduled", "executing"] ->
              retry_counter = Process.get({__MODULE__, job.id, :retry}, 0)

              if retry_counter <= 10 do
                Process.put({__MODULE__, job.id, :retry}, retry_counter + 1)

                exp_backoff = :timer.seconds(1 * (retry_counter * 2))
                Process.sleep(exp_backoff)

                fetch(projection)
              else
                {:error, "The workflow failed to complete within the given timeout."}
              end

            true ->
              {:error, "The workflow failed with status: `#{job.state}`."}
          end
      end
    end
  end
end
