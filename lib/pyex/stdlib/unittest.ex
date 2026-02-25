defmodule Pyex.Stdlib.Unittest do
  @moduledoc """
  Python `unittest` module.

  Provides `TestCase` base class with assertion methods and
  `main()` for test discovery and execution.

  `TestCase` is a real Pyex class value with builtin assertion
  methods. Subclasses define `test_*` methods that are
  discovered and run by `main()`.

  ## Usage in Python

      import unittest

      class TestMath(unittest.TestCase):
          def test_addition(self):
              self.assertEqual(1 + 1, 2)

          def test_subtraction(self):
              self.assertEqual(5 - 3, 2)

      unittest.main()
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Interpreter

  @doc """
  Returns the module value map containing `TestCase` class
  and `main` runner function.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "TestCase" => test_case_class(),
      "main" => {:builtin, &do_main/1}
    }
  end

  @doc """
  Returns the TestCase class value.

  Useful for library consumers who want to reference the class
  directly (e.g. for isinstance checks).
  """
  @spec test_case_class() :: Interpreter.pyvalue()
  def test_case_class do
    {:class, "TestCase", [], assertion_methods()}
  end

  @spec assertion_methods() :: %{optional(String.t()) => Interpreter.pyvalue()}
  defp assertion_methods do
    %{
      "assertEqual" => {:builtin, &assert_equal/1},
      "assertNotEqual" => {:builtin, &assert_not_equal/1},
      "assertTrue" => {:builtin, &assert_true/1},
      "assertFalse" => {:builtin, &assert_false/1},
      "assertIs" => {:builtin, &assert_is/1},
      "assertIsNot" => {:builtin, &assert_is_not/1},
      "assertIsNone" => {:builtin, &assert_is_none/1},
      "assertIsNotNone" => {:builtin, &assert_is_not_none/1},
      "assertIn" => {:builtin, &assert_in/1},
      "assertNotIn" => {:builtin, &assert_not_in/1},
      "assertGreater" => {:builtin, &assert_greater/1},
      "assertGreaterEqual" => {:builtin, &assert_greater_equal/1},
      "assertLess" => {:builtin, &assert_less/1},
      "assertLessEqual" => {:builtin, &assert_less_equal/1},
      "assertAlmostEqual" => {:builtin, &assert_almost_equal/1},
      "assertRaises" => {:builtin, &assert_raises/1},
      "assertIsInstance" => {:builtin, &assert_is_instance/1},
      "fail" => {:builtin, &do_fail/1}
    }
  end

  @spec do_main([Interpreter.pyvalue()]) :: {:unittest_main}
  defp do_main([]), do: {:unittest_main}
  defp do_main(_), do: {:unittest_main}

  @spec assert_equal([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_equal([a, b]) when a == b, do: nil
  defp assert_equal([a, b]), do: assertion_error("#{inspect_py(a)} != #{inspect_py(b)}")

  defp assert_equal([a, b, msg]) do
    if a == b, do: nil, else: assertion_error("#{inspect_py(a)} != #{inspect_py(b)} : #{msg}")
  end

  @spec assert_not_equal([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_not_equal([a, b]) when a != b, do: nil
  defp assert_not_equal([a, b]), do: assertion_error("#{inspect_py(a)} == #{inspect_py(b)}")

  defp assert_not_equal([a, b, msg]) do
    if a != b, do: nil, else: assertion_error("#{inspect_py(a)} == #{inspect_py(b)} : #{msg}")
  end

  @spec assert_true([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_true([val]) do
    if Pyex.Builtins.truthy?(val),
      do: nil,
      else: assertion_error("#{inspect_py(val)} is not true")
  end

  defp assert_true([val, msg]) do
    if Pyex.Builtins.truthy?(val), do: nil, else: assertion_error(msg)
  end

  @spec assert_false([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_false([val]) do
    if Pyex.Builtins.truthy?(val),
      do: assertion_error("#{inspect_py(val)} is not false"),
      else: nil
  end

  defp assert_false([val, msg]) do
    if Pyex.Builtins.truthy?(val), do: assertion_error(msg), else: nil
  end

  @spec assert_is([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_is([a, b]) when a === b, do: nil
  defp assert_is([a, b]), do: assertion_error("#{inspect_py(a)} is not #{inspect_py(b)}")

  @spec assert_is_not([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_is_not([a, b]) when a !== b, do: nil
  defp assert_is_not([a, b]), do: assertion_error("#{inspect_py(a)} is #{inspect_py(b)}")

  @spec assert_is_none([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_is_none([nil]), do: nil
  defp assert_is_none([val]), do: assertion_error("#{inspect_py(val)} is not None")

  @spec assert_is_not_none([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_is_not_none([nil]), do: assertion_error("unexpectedly None")
  defp assert_is_not_none([_val]), do: nil

  @spec assert_in([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_in([item, container]) do
    if member?(item, container),
      do: nil,
      else: assertion_error("#{inspect_py(item)} not found in #{inspect_py(container)}")
  end

  @spec assert_not_in([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_not_in([item, container]) do
    if member?(item, container),
      do: assertion_error("#{inspect_py(item)} unexpectedly found in #{inspect_py(container)}"),
      else: nil
  end

  @spec assert_greater([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_greater([a, b]) when a > b, do: nil

  defp assert_greater([a, b]),
    do: assertion_error("#{inspect_py(a)} not greater than #{inspect_py(b)}")

  @spec assert_greater_equal([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_greater_equal([a, b]) when a >= b, do: nil

  defp assert_greater_equal([a, b]),
    do: assertion_error("#{inspect_py(a)} not greater than or equal to #{inspect_py(b)}")

  @spec assert_less([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_less([a, b]) when a < b, do: nil
  defp assert_less([a, b]), do: assertion_error("#{inspect_py(a)} not less than #{inspect_py(b)}")

  @spec assert_less_equal([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_less_equal([a, b]) when a <= b, do: nil

  defp assert_less_equal([a, b]),
    do: assertion_error("#{inspect_py(a)} not less than or equal to #{inspect_py(b)}")

  @spec assert_almost_equal([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_almost_equal([a, b]) when is_number(a) and is_number(b) do
    if Float.round(a - b + 0.0, 7) == 0.0,
      do: nil,
      else: assertion_error("#{a} != #{b} within 7 places")
  end

  defp assert_almost_equal([a, b, places])
       when is_number(a) and is_number(b) and is_integer(places) do
    if Float.round(a - b + 0.0, places) == 0.0,
      do: nil,
      else: assertion_error("#{a} != #{b} within #{places} places")
  end

  @spec assert_raises([Interpreter.pyvalue()]) :: {:assert_raises, String.t()}
  defp assert_raises([exc_type]) when is_binary(exc_type) do
    {:assert_raises, exc_type}
  end

  defp assert_raises([{:class, name, _, _}]) do
    {:assert_raises, name}
  end

  @spec assert_is_instance([Interpreter.pyvalue()]) :: nil | {:exception, String.t()}
  defp assert_is_instance([{:instance, {:class, name, bases, _}, _}, {:class, target_name, _, _}]) do
    if name == target_name or check_bases(bases, target_name),
      do: nil,
      else: assertion_error("not an instance of #{target_name}")
  end

  defp assert_is_instance([_, _]),
    do: assertion_error("not an instance of the expected type")

  @spec do_fail([Interpreter.pyvalue()]) :: {:exception, String.t()}
  defp do_fail([]), do: assertion_error("explicitly failed")
  defp do_fail([msg]) when is_binary(msg), do: assertion_error(msg)
  defp do_fail([msg]), do: assertion_error(inspect_py(msg))

  @spec assertion_error(String.t()) :: {:exception, String.t()}
  defp assertion_error(msg) do
    {:exception, "AssertionError: #{msg}"}
  end

  @spec member?(Interpreter.pyvalue(), Interpreter.pyvalue()) :: boolean()
  defp member?(item, {:py_list, reversed, _}), do: item in reversed
  defp member?(item, list) when is_list(list), do: item in list
  defp member?(item, {:tuple, items}), do: item in items
  defp member?(item, {:set, s}), do: MapSet.member?(s, item)
  defp member?(key, map) when is_map(map), do: Map.has_key?(map, key)

  defp member?(substr, str) when is_binary(substr) and is_binary(str),
    do: String.contains?(str, substr)

  defp member?(_, _), do: false

  @spec check_bases([Interpreter.pyvalue()], String.t()) :: boolean()
  defp check_bases([], _target), do: false

  defp check_bases(bases, target) do
    Enum.any?(bases, fn
      {:class, name, sub_bases, _} ->
        name == target or check_bases(sub_bases, target)

      _ ->
        false
    end)
  end

  @spec inspect_py(Interpreter.pyvalue()) :: String.t()
  defp inspect_py(nil), do: "None"
  defp inspect_py(true), do: "True"
  defp inspect_py(false), do: "False"
  defp inspect_py(val) when is_binary(val), do: "'#{val}'"
  defp inspect_py(val) when is_integer(val), do: Integer.to_string(val)
  defp inspect_py(val) when is_float(val), do: Float.to_string(val)
  defp inspect_py(list) when is_list(list), do: "[#{Enum.map_join(list, ", ", &inspect_py/1)}]"
  defp inspect_py({:tuple, items}), do: "(#{Enum.map_join(items, ", ", &inspect_py/1)})"

  defp inspect_py({:set, s}),
    do: "{#{s |> MapSet.to_list() |> Enum.map_join(", ", &inspect_py/1)}}"

  defp inspect_py(map) when is_map(map) do
    inner =
      map
      |> Pyex.Builtins.visible_dict()
      |> Enum.map_join(", ", fn {k, v} -> "#{inspect_py(k)}: #{inspect_py(v)}" end)

    "{#{inner}}"
  end

  defp inspect_py({:class, name, _, _}), do: "<class '#{name}'>"
  defp inspect_py({:instance, {:class, name, _, _}, _}), do: "<#{name} instance>"
  defp inspect_py(other), do: inspect(other)
end
