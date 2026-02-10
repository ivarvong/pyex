defmodule Pyex.Interpreter.Unittest do
  @moduledoc """
  Python `unittest` test runner.

  Discovers `TestCase` subclasses in the environment, runs their
  `test*` methods with `setUp`/`tearDown` lifecycle, and produces
  formatted output via `Ctx.record/3`.
  """

  alias Pyex.{Ctx, Env, Interpreter}

  @doc """
  Runs `unittest.main()` — discovers and executes all test classes.

  Returns a summary dict with keys `total`, `passed`, `failures`,
  `errors`, and `success`.
  """
  @spec eval_unittest_main(Env.t(), Ctx.t()) ::
          {Interpreter.pyvalue(), Env.t(), Ctx.t()}
  def eval_unittest_main(env, ctx) do
    test_case_class = Pyex.Stdlib.Unittest.test_case_class()
    {:class, tc_name, _, _} = test_case_class

    test_classes = discover_test_classes(env, tc_name)

    {results, env, ctx} =
      Enum.reduce(test_classes, {[], env, ctx}, fn {:class, class_name, _, class_attrs} = class,
                                                   {results, env, ctx} ->
        test_methods =
          class_attrs
          |> Map.keys()
          |> Enum.filter(&String.starts_with?(&1, "test"))
          |> Enum.sort()

        {class_results, env, ctx} =
          Enum.reduce(test_methods, {[], env, ctx}, fn method_name, {acc, env, ctx} ->
            {result, env, ctx} =
              run_test_method(class, class_name, method_name, class_attrs, env, ctx)

            {[{class_name, method_name, result} | acc], env, ctx}
          end)

        {results ++ Enum.reverse(class_results), env, ctx}
      end)

    ctx = print_test_results(results, ctx)
    {format_test_summary(results), env, ctx}
  end

  @spec discover_test_classes(Env.t(), String.t()) :: [Interpreter.pyvalue()]
  defp discover_test_classes(env, tc_name) do
    env
    |> Env.all_bindings()
    |> Enum.filter(fn {_name, value} ->
      case value do
        {:class, _name, bases, _attrs} when bases != [] ->
          has_test_case_base?(bases, tc_name)

        _ ->
          false
      end
    end)
    |> Enum.map(fn {_name, class} -> class end)
  end

  @spec has_test_case_base?([Interpreter.pyvalue()], String.t()) :: boolean()
  defp has_test_case_base?(bases, target_name) do
    Enum.any?(bases, fn
      {:class, name, sub_bases, _} ->
        name == target_name or has_test_case_base?(sub_bases, target_name)

      _ ->
        false
    end)
  end

  @spec run_test_method(
          Interpreter.pyvalue(),
          String.t(),
          String.t(),
          map(),
          Env.t(),
          Ctx.t()
        ) ::
          {:ok | {:fail, String.t()} | {:error, String.t()}, Env.t(), Ctx.t()}
  defp run_test_method(class, _class_name, method_name, class_attrs, env, ctx) do
    case Interpreter.call_function(class, [], %{}, env, ctx) do
      {{:exception, msg}, env, ctx} ->
        {{:error, "setUp failed: #{msg}"}, env, ctx}

      {instance, env, ctx} when is_tuple(instance) ->
        {instance, env, ctx} = maybe_call_setup(instance, class_attrs, env, ctx)

        case instance do
          {:exception, msg} ->
            {{:error, "setUp failed: #{msg}"}, env, ctx}

          _ ->
            {result, env, ctx} = run_single_test(instance, method_name, class_attrs, env, ctx)
            {_instance, env, ctx} = maybe_call_teardown(instance, class_attrs, env, ctx)
            {result, env, ctx}
        end

      {_, env, ctx} ->
        {{:error, "could not instantiate test class"}, env, ctx}
    end
  end

  @spec maybe_call_setup(Interpreter.pyvalue(), map(), Env.t(), Ctx.t()) ::
          {Interpreter.pyvalue(), Env.t(), Ctx.t()}
  defp maybe_call_setup(instance, class_attrs, env, ctx) do
    case Map.fetch(class_attrs, "setUp") do
      {:ok, {:function, _, _, _, _} = func} ->
        case Interpreter.call_function({:bound_method, instance, func}, [], %{}, env, ctx) do
          {{:exception, _} = signal, _env, ctx} -> {signal, env, ctx}
          {:mutate, _updated_self, {:exception, _} = signal, ctx} -> {signal, env, ctx}
          {:mutate, updated_self, _val, ctx} -> {updated_self, env, ctx}
          {_val, _env, ctx, _} -> {instance, env, ctx}
          {_val, _env, ctx} -> {instance, env, ctx}
        end

      _ ->
        {instance, env, ctx}
    end
  end

  @spec maybe_call_teardown(Interpreter.pyvalue(), map(), Env.t(), Ctx.t()) ::
          {Interpreter.pyvalue(), Env.t(), Ctx.t()}
  defp maybe_call_teardown(instance, class_attrs, env, ctx) do
    case Map.fetch(class_attrs, "tearDown") do
      {:ok, {:function, _, _, _, _} = func} ->
        case Interpreter.call_function({:bound_method, instance, func}, [], %{}, env, ctx) do
          {{:exception, _}, _env, ctx} -> {instance, env, ctx}
          {:mutate, updated_self, _val, ctx} -> {updated_self, env, ctx}
          {_val, _env, ctx, _} -> {instance, env, ctx}
          {_val, _env, ctx} -> {instance, env, ctx}
        end

      _ ->
        {instance, env, ctx}
    end
  end

  @spec run_single_test(Interpreter.pyvalue(), String.t(), map(), Env.t(), Ctx.t()) ::
          {:ok | {:fail, String.t()} | {:error, String.t()}, Env.t(), Ctx.t()}
  defp run_single_test(instance, method_name, class_attrs, env, ctx) do
    case Map.fetch(class_attrs, method_name) do
      {:ok, {:function, _, _, _, _} = func} ->
        case Interpreter.call_function({:bound_method, instance, func}, [], %{}, env, ctx) do
          {{:exception, "AssertionError" <> _ = msg}, env, ctx} ->
            {{:fail, msg}, env, ctx}

          {{:exception, msg}, env, ctx} ->
            {{:error, msg}, env, ctx}

          {:mutate, _updated_self, {:exception, "AssertionError" <> _ = msg}, ctx} ->
            {{:fail, msg}, env, ctx}

          {:mutate, _updated_self, {:exception, msg}, ctx} ->
            {{:error, msg}, env, ctx}

          {:mutate, _updated_self, _return_val, ctx} ->
            {:ok, env, ctx}

          {_val, env, ctx, _updated_func} ->
            {:ok, env, ctx}

          {_val, env, ctx} ->
            {:ok, env, ctx}
        end

      _ ->
        {{:error, "test method '#{method_name}' not found"}, env, ctx}
    end
  end

  @spec print_test_results(
          [{String.t(), String.t(), :ok | {:fail, String.t()} | {:error, String.t()}}],
          Ctx.t()
        ) :: Ctx.t()
  defp print_test_results(results, ctx) do
    ctx =
      Enum.reduce(results, ctx, fn {class_name, method_name, result}, ctx ->
        case result do
          :ok ->
            Ctx.record(ctx, :output, "#{method_name} (#{class_name}) ... ok")

          {:fail, msg} ->
            ctx = Ctx.record(ctx, :output, "#{method_name} (#{class_name}) ... FAIL")
            Ctx.record(ctx, :output, "  #{msg}")

          {:error, msg} ->
            ctx = Ctx.record(ctx, :output, "#{method_name} (#{class_name}) ... ERROR")
            Ctx.record(ctx, :output, "  #{msg}")
        end
      end)

    total = length(results)
    failures = Enum.count(results, fn {_, _, r} -> match?({:fail, _}, r) end)
    errors = Enum.count(results, fn {_, _, r} -> match?({:error, _}, r) end)

    ctx = Ctx.record(ctx, :output, "")

    ctx =
      Ctx.record(
        ctx,
        :output,
        "----------------------------------------------------------------------"
      )

    ctx = Ctx.record(ctx, :output, "Ran #{total} test#{if total != 1, do: "s", else: ""}")
    ctx = Ctx.record(ctx, :output, "")

    if failures == 0 and errors == 0 do
      Ctx.record(ctx, :output, "OK")
    else
      parts =
        [
          if(failures > 0, do: "failures=#{failures}"),
          if(errors > 0, do: "errors=#{errors}")
        ]
        |> Enum.reject(&is_nil/1)

      Ctx.record(ctx, :output, "FAILED (#{Enum.join(parts, ", ")})")
    end
  end

  @spec format_test_summary([
          {String.t(), String.t(), :ok | {:fail, String.t()} | {:error, String.t()}}
        ]) ::
          Interpreter.pyvalue()
  defp format_test_summary(results) do
    total = length(results)
    failures = Enum.count(results, fn {_, _, r} -> match?({:fail, _}, r) end)
    errors = Enum.count(results, fn {_, _, r} -> match?({:error, _}, r) end)
    passed = total - failures - errors

    %{
      "total" => total,
      "passed" => passed,
      "failures" => failures,
      "errors" => errors,
      "success" => failures == 0 and errors == 0
    }
  end
end
