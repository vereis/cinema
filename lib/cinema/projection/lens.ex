defmodule Cinema.Projection.Lens do
  @moduledoc """
  The `#{__MODULE__}` module provides a struct for defining lenses which can be used to manipulate
  the inputs to a given projection.

  Lenses can be used to filter, scope, or otherwise manipulate the inputs to a given projection.

  See the `#{__MODULE__}.apply/3` and `#{__MODULE__}.build!/2` functions for more information.
  """

  import Ecto.Query

  alias __MODULE__
  alias Cinema.Projection

  @type t :: %__MODULE__{}
  defstruct [:reducer, filters: []]

  @doc """
  Builds a new `#{__MODULE__}.t()` struct with the given `filters` and optional `reducer`.
  See `#{__MODULE__}.apply/3` for more information.
  """
  @spec build!(
          filters :: list(),
          ({filter :: atom(), value :: term()}, acc :: Ecto.Query.t() | module() -> Ecto.Query.t() | module()) | nil
        ) :: t()
  def build!(filters, reducer \\ nil) when is_list(filters) do
    %__MODULE__{filters: filters, reducer: reducer}
  end

  @doc """
  Uses the given `#{__MODULE__}.t()` to manipulate inputs to the given projection.

  If the given `#{__MODULE__}.t()` has a `reducer` function, a given input projection's output
  will be reduced over with the given `filters`, allowing you to customize the behaviour of how
  a projection's inputs are scoped or modified.

  If the given `#{__MODULE__}.t()` does not have a `reducer` function, the given `filters` will
  be used to filter the given input projection's output the same way `Ecto.Query.where/3` does
  when given a static `Keyword.t()` as a final argument.

  Returns either the manipulated queryable, or a stream capturing said queryable depending on if
  `as_stream: true` is passed in the `opts` argument.
  """
  @spec apply(t(), module(), Keyword.t()) :: Enumerable.t() | Ecto.Query.t()
  def apply(%Lens{} = lens, projection, opts \\ []) when is_atom(projection) do
    unless Projection.implemented?(projection) do
      raise ArgumentError,
        message: "The given projection does not implement the `Cinema.Projection` behaviour."
    end

    output = projection.output()

    if is_struct(output, Ecto.Query) or is_atom(output) do
      query =
        if is_nil(lens.reducer) do
          fields = projection.fields()
          filters = Keyword.take(lens.filters, fields)
          from(x in output, where: ^filters)
        else
          Enum.reduce(lens.filters, output, lens.reducer)
        end

      if opts[:as_stream] do
        (projection.opts[:read_repo] || projection.opts[:write_repo] || projection.opts[:repo]).stream(query)
      else
        query
      end
    else
      Stream.filter(output, &Enum.all?(lens.filters, fn {k, v} -> &1[k] == v end))
    end
  end
end
