defmodule Cinema.Utils do
  @moduledoc false

  @spec sanitize_timestamps(map :: map()) :: map()
  def sanitize_timestamps(map) when is_map_key(map, :inserted_at) or is_map_key(map, :updated_at) do
    map
    |> Map.update(:inserted_at, nil, &NaiveDateTime.truncate(&1, :second))
    |> Map.update(:updated_at, nil, &NaiveDateTime.truncate(&1, :second))
  end

  def sanitize_timestamps(map) do
    map
  end

  @spec implemented?(module(), behaviour :: module()) :: boolean()
  def implemented?(module, behaviour) do
    behaviours =
      :attributes
      |> module.module_info()
      |> Enum.filter(&match?({:behaviour, _behaviours}, &1))
      |> Enum.map(&elem(&1, 1))
      |> List.flatten()

    behaviour in behaviours
  end
end
