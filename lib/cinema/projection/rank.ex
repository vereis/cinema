defmodule Cinema.Projection.Rank do
  @moduledoc """
  This module is responsible for ranking a list of projections in a depth-first manner, which can
  be used to determine the order in which to execute a list of projections, potentially asynchronously.

  The `derive/2` function is the main entry point, which takes a list of projections and a single
  target projection you'd like to run. The function will then proceed to rank all dependencts of the
  target projection recursively.

  Note that a single dependency can appear multiple times due to being dependents of different subgraphs
  of the target projection. In this case, the dependency will be ranked multiple times, but the final
  ranking will be the highest rank of all duplicate dependencies.

  Ranked projections can then be grouped by rank, and the groups can be executed in parallel, as they
  are guaranteed to be independent of each other.

  See the `depth_first_rank/2` function for more details on how the ranking is actually done.
  """

  @doc """
  Derives the dependency order of a target projection in a list of projections by ranking them in a
  depth-first manner.

  Projections are expected to be given in the form: `[{Module.t(), [Module.t()]}]`

  Note that the order of the returned list is derived simply from the declared hierarchy of the projections,
  and does not take into account any additional processing that may be required to actually execute
  the projections. This means that the order of the returned list may not be the optimal order for
  execution, but it will guarantee that all dependencies are executed before the target projection.

  Additionally, the algorithm used is simple in that it "lazily" ranks dependencies after the whole graph
  has been traversed, and does not attempt to optimize the ranking in any way. A graph could theoretically
  take into consideration "re-ranking" of dependencies in an attempt to optimize ordering/grouping, but
  this is not currently implemented.

  Also do note that currently this function does not handle cycles in the graph, and will raise an error
  if a cycle is detected.

  See examples:

    ```elixir
    iex> alias #{__MODULE__}
    iex> graph = [a: [], b: [], c: [:a, :b], d: [:c], e: [:b], f: [:c, :e]]
    iex> Rank.derive!(graph, :d)
    [[:a, :b], :c, :d]
    iex> Rank.derive!(graph, :e)
    [:b, :e]
    iex> Rank.derive!(graph, :a)
    [:a]
    iex> # This isn't neccessarily the optimal order, but it is _correct_.
    iex> Rank.derive!(graph, :f)
    [[:a, :b], [:c, :e], :f]
    ```
  """
  @spec derive!([{module() | [module()]}], module()) :: [module() | [module()]]
  def derive!(projections, projection) do
    # TODO: pretty sure we can raise from `depth_first_rank/2` if a cycle is detected
    #       but I'm not bothered to figure this out right now!
    ranked_map =
      projections
      |> Enum.sort()
      |> depth_first_rank(projection)
      |> Enum.reduce(%{}, fn {idx, node}, acc ->
        Map.update(acc, node, idx, &((&1 < idx && idx) || &1))
      end)

    max_rank =
      ranked_map
      |> Enum.max_by(fn {_, idx} -> idx end)
      |> elem(1)

    async_groups =
      for rank <- 0..max_rank do
        ranked_map
        |> Enum.filter(fn {_, idx} -> idx == rank end)
        |> Enum.map(fn {node, _} -> node end)
      end

    async_groups |> Enum.map(&((match?([_], &1) && hd(&1)) || &1)) |> Enum.reverse()
  end

  @doc """
  Recursively traverses a list of KV tuples representing a graph of projections and their dependencies,
  and ranks them in a depth-first manner.

  Does not do any additional processing on the ranked projections, see `derive/2` for that.
  """
  @spec depth_first_rank([{module() | [module()]}], module()) :: [{integer(), module()}]
  def depth_first_rank(projections, projection) do
    projections
    |> Enum.reject(fn x -> match?({_, []}, x) end)
    |> Map.new()
    |> depth_first_rank(projection, 0)
  end

  defp depth_first_rank(projections, projection, idx) when not is_map_key(projections, projection) do
    [{idx, projection}]
  end

  defp depth_first_rank(projections, projection, idx) do
    [
      {idx, projection}
      | projections[projection]
        |> Enum.map(fn projection -> depth_first_rank(projections, projection, idx + 1) end)
        |> List.flatten()
    ]
  end
end
