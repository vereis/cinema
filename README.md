# Cinema

Cinema is a simple Elixir framework for managing incremental materialized views entirely in Elixir/Ecto.

## Installation

Cinema can be installed by adding `cinema` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:cinema, "~> 0.1.0"}
  ]
end
```

Cinema has an optional dependency on [Oban Pro](https://getoban.pro) as an alternate runtime for materializing projection graphs. Oban Pro support is automatically enabled if `Hex` detects the `oban` repo in your global setup.

Please see the [Oban Pro](https://getoban.pro) documentation for more information on how to install and configure Oban Pro.

## Usage

Cinema introduces two basic concepts:

- **Projections**: A projection is a behaviour that allows you to declaratively define instructions in Elixir for how to derive rows to write into your materialized views. They statically define all `c:inputs/0` (other projections, if needed), `c:output/1` (usually an `Ecto.Query` or stream passed into subsequent projections), and a `c:derivation/2` callback which is run in tandem with all inputs to produce output.
- **Lenses**: A lens is a struct which contains filters and other options which can be used to modify the "scope" of what a projection is required to derive. In simple use cases, you can think of lenses as automatically applying filters such as: `where: x.org_id == ^org_id` to the outputs of all input projections automatically.

When you want to actually incrementally rematerialize a view, you create a `Cinema.Lens.t()` (or a simple keyword list for simple filters), and pass that into the `Cinema.project/3` function like so:

```elixir
iex> Cinema.project(MyApp.Projections.AccountsReceivable, [org_id: 123, date: ~D[2022-01-01]])
[
  %MyApp.Projections.AccountsReceivable{
    org_id: 123,
    date: ~D[2022-01-01],
    ...
  },
  ...
]
```

Projections generally define their own `Ecto.Schema` internally and can also be queried directly -- note that this will not rematerialize any dependencies or rows in the table you're querying:

```elixir
iex> MyApp.Repo.all(MyApp.Projections.AccountsReceivable)
[
  %MyApp.Projections.AccountsReceivable{
    org_id: 123,
    date: ~D[2022-01-01],
    ...
  },
  ...
]
```

Projections can include other projections as inputs, and Cinema will automatically rematerialize those projections as needed. For example, if `AccountsReceivable` depends on `Invoices`, Cinema will automatically rematerialize `Invoices` before rematerializing `AccountsReceivable`.

Projection graphs usually begin with "virtual" projections that have no inputs or `derivation/2` callback, instead only outputting either an `Ecto.Query` or stream which is passed directly through any `Cinema.Lens.t()` and into the next projection in the graph.

Cinema does this by building a DAG of all projections and their dependencies. Cinema will likewise try to run any projections in parallel where possible. A minimal example of a projection looks like the following:

```elixir
defmodule MyApp.Projections.Accounts do
  use Cinema.Projection, virtual?: true

  @impl Cinema.Projection
  def inputs, do: []

  @impl Cinema.Projection
  def output, do: from(a in "accounts", select: a.id)
end

defmodule MyApp.Projections.AccountsReceivable do
  use Cinema.Projection,
    conflict_target: [:account_id],
    required_fields: [:account_id],
    on_conflict: :replace_all,
    read_repo: MyApp.Repo.Replica,
    write_repo: MyApp.Repo,
    timeout: :timer.minutes(5),

  alias Cinema.Projection
  alias MyApp.Projections.Accounts

  @primary_key false
  schema "accounts_receivable" do
    field(account_id:, :id)
    field(total, :integer)

    timestamps()
  end

  @impl Cinema.Projection
  def inputs, do: [Accounts]

  @impl Cinema.Projection
  def output, do: from(a in "accounts_receivable", select: a)

  @impl Cinema.Projection
  def derivation({Accounts, stream}, lens) do
    Projection.dematerialize(lens)

    stream
    |> Stream.chunk_every(2000)
    |> Stream.map(&from x in MyApp.Invoice, where: x.account_id in ^&1, select: %{account_id: x.account_id, total: sum(x.total)})
    |> Stream.map(&Projection.materialize/1)
    |> Stream.run()
  end
end
```

### Configuration

Currently, Cinema lets you configure the following options:

- `:engine` - The runtime to use for executing projection graphs. Defaults to `Cinema.Engine.Task`.
- `:async` - Whether to run projections asynchronously. Defaults to `true`.

Additional configuration options can be implemented on a projection-by-projection basis, please see the docs for the `Cinema.Projection` behaviour for more information.

## License

Cinema is released under the [MIT License](LICENSE.md).
