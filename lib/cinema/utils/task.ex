defmodule Cinema.Utils.Task do
  @moduledoc false

  @spec async((-> term())) :: term()
  def async(func) when is_function(func, 0) do
    if test_mode?() do
      func.()
    else
      Task.async(func)
    end
  end

  @spec await(term(), timeout :: non_neg_integer()) :: term()
  def await(task, timeout) do
    if test_mode?() do
      task
    else
      Task.await(task, timeout)
    end
  end

  @spec await_many([term()], timeout :: non_neg_integer()) :: [term()]
  def await_many(tasks, timeout) do
    if test_mode?() do
      tasks
    else
      Task.await_many(tasks, timeout)
    end
  end

  @doc "Returns `true` if the current process is running in test mode, otherwise returns `false`."
  @spec test_mode?() :: boolean()
  def test_mode? do
    Process.get({__MODULE__, :test_mode}, false)
  end

  @doc "Sets the test mode to the given boolean value. When in test mode, all Task functions will be executed synchronously."
  @spec test_mode(boolean()) :: :ok
  def test_mode(bool) when is_boolean(bool) do
    Process.put({__MODULE__, :test_mode}, bool)
    :ok
  end
end
