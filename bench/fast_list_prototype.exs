defmodule Pyex.FastList do
  @moduledoc """
  Prototype: Reverse-storage list for O(1) append operations.

  Stores elements in reverse order internally:
  - Python [1, 2, 3, 4, 5] is stored as {:rlist, [5, 4, 3, 2, 1], 5}
  - Append becomes [new_elem | reversed_items] (O(1) cons)
  - Index 0 maps to index (length-1) in reversed storage

  Trade-offs:
  - append/extend: O(n) → O(1)
  - indexing: O(n) stays O(n), but with index transformation
  - iteration: reverse before returning (or iterate backwards)
  - pop: O(n) → O(1) for last element (which is first in storage)
  """

  @type t :: {:rlist, [term()], non_neg_integer()}

  @doc """
  Create a new empty reverse-storage list.
  """
  @spec new() :: t()
  def new(), do: {:rlist, [], 0}

  @doc """
  Create from a regular list. Reverses for storage.
  """
  @spec from_list([term()]) :: t()
  def from_list(items) when is_list(items) do
    {:rlist, Enum.reverse(items), length(items)}
  end

  @doc """
  Convert back to regular list (reverses storage).
  """
  @spec to_list(t()) :: [term()]
  def to_list({:rlist, reversed, _len}), do: Enum.reverse(reversed)

  @doc """
  O(1) append operation.
  """
  @spec append(t(), term()) :: t()
  def append({:rlist, reversed, len}, item) do
    {:rlist, [item | reversed], len + 1}
  end

  @doc """
  O(1) pop from end (Python's default pop()).
  Returns {value, new_list} or nil if empty.
  """
  @spec pop(t()) :: {term(), t()} | nil
  def pop({:rlist, [], 0}), do: nil

  def pop({:rlist, [head | tail], len}) do
    {head, {:rlist, tail, len - 1}}
  end

  @doc """
  O(1) pop from specific index (still O(n) in middle, O(1) at end).
  """
  @spec pop_at(t(), integer()) :: {term(), t()} | {:error, String.t()}
  def pop_at({:rlist, [], 0}, _index), do: {:error, "IndexError: pop from empty list"}

  def pop_at({:rlist, reversed, len}, index) when is_integer(index) do
    # Convert Python index to reversed storage index
    # Python index 0 = last element in reversed storage
    # Python index -1 = first element in reversed storage
    real_index =
      if index < 0 do
        # Negative indexing from end
        -index - 1
      else
        len - 1 - index
      end

    if real_index < 0 or real_index >= len do
      {:error, "IndexError: pop index out of range"}
    else
      value = Enum.at(reversed, real_index)
      # Remove at position and rebuild
      {before, [_ | rest]} = Enum.split(reversed, real_index)
      new_reversed = before ++ rest
      {value, {:rlist, new_reversed, len - 1}}
    end
  end

  @doc """
  O(n) indexing with transformed index.
  """
  @spec get(t(), integer()) :: term() | {:error, String.t()}
  def get({:rlist, _reversed, len}, index) when index >= len or index < -len do
    {:error, "IndexError: list index out of range"}
  end

  def get({:rlist, reversed, len}, index) do
    real_index =
      if index < 0 do
        -index - 1
      else
        len - 1 - index
      end

    Enum.at(reversed, real_index)
  end

  @doc """
  O(n) extend (optimized - just prepend reversed other list).
  """
  @spec extend(t(), [term()]) :: t()
  def extend({:rlist, reversed, len}, items) when is_list(items) do
    # Prepend reversed items to reversed storage
    {:rlist, Enum.reverse(items) ++ reversed, len + length(items)}
  end

  @doc """
  Get length.
  """
  @spec len(t()) :: non_neg_integer()
  def len({:rlist, _, length}), do: length
end

defmodule Pyex.FastList.Benchmark do
  @moduledoc """
  Benchmark comparing regular list vs reverse-storage list for append operations.
  """

  def run do
    test_sizes = [10, 50, 100, 200, 500, 1000]

    IO.puts("=" |> String.duplicate(70))
    IO.puts("List Append Performance: Linked List vs Reverse-Storage")
    IO.puts("=" |> String.duplicate(70))
    IO.puts("")

    IO.puts("Building lists by repeated append in a loop")
    IO.puts("")

    IO.puts(
      "#{String.pad_trailing("Items", 8)} #{String.pad_trailing("Linked List", 15)} #{String.pad_trailing("Reverse-Storage", 15)} #{String.pad_trailing("Speedup", 10)}"
    )

    IO.puts(String.duplicate("-", 50))

    for n <- test_sizes do
      linked_time = benchmark_linked_list(n)
      reverse_time = benchmark_reverse_storage(n)
      speedup = linked_time / reverse_time

      IO.puts(
        "#{String.pad_trailing("#{n}", 8)} #{String.pad_trailing("#{Float.round(linked_time, 2)} µs", 15)} #{String.pad_trailing("#{Float.round(reverse_time, 2)} µs", 15)} #{Float.round(speedup, 1)}x"
      )
    end

    IO.puts("")
    IO.puts("Index access comparison (n=100):")
    IO.puts("  Linked list index 50: #{benchmark_linked_index()} µs")
    IO.puts("  Reverse-storage index 50: #{benchmark_reverse_index()} µs")
    IO.puts("")
    IO.puts("Key insight:")
    IO.puts("  - Reverse-storage gives O(1) append (cons operation)")
    IO.puts("  - Indexing cost is similar (both O(n) traversal)")
    IO.puts("  - For append-heavy workloads, 10-100x faster")
    IO.puts("  - Comprehensions still win (O(n) vs O(n²))")
  end

  defp benchmark_linked_list(n) do
    {time, _} =
      :timer.tc(fn ->
        for _ <- 1..1000 do
          Enum.reduce(0..(n - 1), [], fn i, acc ->
            # O(n) append
            acc ++ [i]
          end)
        end
      end)

    time / 1000
  end

  defp benchmark_reverse_storage(n) do
    alias Pyex.FastList, as: FL

    {time, _} =
      :timer.tc(fn ->
        for _ <- 1..1000 do
          list = FL.new()

          list =
            Enum.reduce(0..(n - 1), list, fn i, acc ->
              # O(1) append
              FL.append(acc, i)
            end)

          # Convert back (reverse operation)
          FL.to_list(list)
        end
      end)

    time / 1000
  end

  defp benchmark_linked_index do
    list = Enum.to_list(0..99)

    {time, _} =
      :timer.tc(fn ->
        for _ <- 1..10_000 do
          Enum.at(list, 50)
        end
      end)

    time / 10_000
  end

  defp benchmark_reverse_index do
    alias Pyex.FastList, as: FL
    list = FL.from_list(Enum.to_list(0..99))

    {time, _} =
      :timer.tc(fn ->
        for _ <- 1..10_000 do
          FL.get(list, 50)
        end
      end)

    time / 10_000
  end
end

# Run the benchmark
Pyex.FastList.Benchmark.run()
