defmodule Pyex.Stdlib.Random do
  @moduledoc """
  Python `random` module backed by Erlang's `:rand`.

  Provides `randint`, `random`, `choice`, `shuffle`,
  `uniform`, `randrange`, `sample`, and `seed`.
  """

  @behaviour Pyex.Stdlib.Module

  @doc """
  Returns the module value map.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "randint" => {:builtin, &do_randint/1},
      "random" => {:builtin, &do_random/1},
      "choice" => {:builtin, &do_choice/1},
      "shuffle" => {:builtin, &do_shuffle/1},
      "uniform" => {:builtin, &do_uniform/1},
      "randrange" => {:builtin, &do_randrange/1},
      "sample" => {:builtin, &do_sample/1},
      "seed" => {:builtin, &do_seed/1}
    }
  end

  @spec do_randint([Pyex.Interpreter.pyvalue()]) :: integer()
  defp do_randint([a, b]) when is_integer(a) and is_integer(b) do
    a + :rand.uniform(b - a + 1) - 1
  end

  @spec do_random([Pyex.Interpreter.pyvalue()]) :: float()
  defp do_random([]), do: :rand.uniform()

  @spec do_choice([Pyex.Interpreter.pyvalue()]) ::
          Pyex.Interpreter.pyvalue() | {:exception, String.t()}
  defp do_choice([{:py_list, _, 0}]),
    do: {:exception, "IndexError: Cannot choose from an empty sequence"}

  defp do_choice([{:py_list, reversed, _len}]) do
    Enum.random(reversed)
  end

  defp do_choice([list]) when is_list(list) and list != [] do
    Enum.random(list)
  end

  defp do_choice([[]]),
    do: {:exception, "IndexError: Cannot choose from an empty sequence"}

  defp do_choice([str]) when is_binary(str) and str != "" do
    str |> String.codepoints() |> Enum.random()
  end

  @spec do_shuffle([Pyex.Interpreter.pyvalue()]) ::
          {:mutate_arg, non_neg_integer(), Pyex.Interpreter.pyvalue(), nil}
          | {:exception, String.t()}
  # Python's random.shuffle mutates in place.  We signal a mutation of
  # argument 0 so the caller's list reference is updated.
  defp do_shuffle([{:py_list, reversed, len}]) do
    shuffled = Enum.shuffle(reversed)
    {:mutate_arg, 0, {:py_list, shuffled, len}, nil}
  end

  defp do_shuffle([list]) when is_list(list) do
    {:mutate_arg, 0, Enum.shuffle(list), nil}
  end

  @spec do_uniform([Pyex.Interpreter.pyvalue()]) :: float()
  defp do_uniform([a, b]) when is_number(a) and is_number(b) do
    a + :rand.uniform() * (b - a)
  end

  @spec do_randrange([Pyex.Interpreter.pyvalue()]) :: integer()
  defp do_randrange([stop]) when is_integer(stop) and stop > 0 do
    :rand.uniform(stop) - 1
  end

  defp do_randrange([start, stop]) when is_integer(start) and is_integer(stop) and start < stop do
    start + :rand.uniform(stop - start) - 1
  end

  defp do_randrange([start, stop, step])
       when is_integer(start) and is_integer(stop) and is_integer(step) and step > 0 do
    range = start..(stop - 1)//step |> Enum.to_list()
    Enum.random(range)
  end

  @spec do_sample([Pyex.Interpreter.pyvalue()]) ::
          Pyex.Interpreter.pyvalue() | {:exception, String.t()}
  defp do_sample([{:py_list, reversed, len}, k]) when is_integer(k) and k >= 0 do
    if k > len do
      {:exception, "ValueError: Sample larger than population"}
    else
      sampled = Enum.take_random(reversed, k)
      {:py_list, sampled, length(sampled)}
    end
  end

  defp do_sample([list, k]) when is_list(list) and is_integer(k) and k >= 0 do
    if k > length(list) do
      {:exception, "ValueError: Sample larger than population"}
    else
      Enum.take_random(list, k)
    end
  end

  defp do_sample([{:range, start, stop, step}, k]) when is_integer(k) and k >= 0 do
    case Pyex.Builtins.range_to_list({:range, start, stop, step}) do
      {:exception, _} = e ->
        e

      items when is_list(items) ->
        if k > length(items) do
          {:exception, "ValueError: Sample larger than population"}
        else
          Enum.take_random(items, k)
        end
    end
  end

  defp do_sample([{:tuple, items}, k]) when is_integer(k) and k >= 0 do
    if k > length(items) do
      {:exception, "ValueError: Sample larger than population"}
    else
      Enum.take_random(items, k)
    end
  end

  defp do_sample([str, k]) when is_binary(str) and is_integer(k) and k >= 0 do
    items = String.codepoints(str)

    if k > length(items) do
      {:exception, "ValueError: Sample larger than population"}
    else
      Enum.take_random(items, k)
    end
  end

  defp do_sample(_args) do
    {:exception, "TypeError: sample() requires a population and a sample size"}
  end

  @spec do_seed([Pyex.Interpreter.pyvalue()]) :: nil
  defp do_seed([n]) when is_integer(n) do
    :rand.seed(:exsss, {n, n, n})
    nil
  end

  defp do_seed([]), do: do_seed([0])
end
