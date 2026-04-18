defmodule Pyex.Interpreter.CallSupport do
  @moduledoc """
  Parameter binding and call-result bookkeeping helpers for `Pyex.Interpreter`.

  Keeps the mechanical parts of function invocation separate from the main
  callable dispatch so `call_function/5` can stay focused on callable kinds.
  """

  alias Pyex.{Ctx, Env, Interpreter, Parser, PyDict}

  @typep call_result :: term()

  @doc false
  @spec bind_params(
          [Parser.param()],
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: {Env.t(), Ctx.t()} | {:exception, String.t(), Ctx.t()}
  def bind_params(params, args, kwargs, env, ctx) do
    if kwargs == %{} and simple_positional?(params, args) do
      bind_simple(params, args, env, ctx)
    else
      bind_params_full(params, args, kwargs, env, ctx)
    end
  end

  @spec simple_positional?([Parser.param()], [Interpreter.pyvalue()]) :: boolean()
  defp simple_positional?(params, args) do
    length(params) == length(args) and
      not Enum.any?(params, fn param ->
        name = elem(param, 0)
        String.starts_with?(name, "*") or name == "*"
      end)
  end

  @spec bind_simple([Parser.param()], [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          {Env.t(), Ctx.t()}
  defp bind_simple([], [], env, ctx), do: {env, ctx}

  defp bind_simple([param | params], [arg | args], env, ctx) do
    name = elem(param, 0)
    bind_simple(params, args, Env.put(env, name, arg), ctx)
  end

  @spec bind_params_full(
          [Parser.param()],
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: {Env.t(), Ctx.t()} | {:exception, String.t(), Ctx.t()}
  defp bind_params_full(params, args, kwargs, env, ctx) do
    {regular, star_param, kwonly_params, dstar_param} = split_variadic_params(params)
    regular_names = Enum.map(regular, &elem(&1, 0))
    defaults = Enum.map(regular, &elem(&1, 1))
    n_regular = length(regular)
    n_args = length(args)

    has_star = star_param != nil
    has_dstar = dstar_param != nil

    if n_args > n_regular and not has_star do
      {:exception,
       "TypeError: function takes #{n_regular} positional arguments but #{n_args} were given",
       ctx}
    else
      positional = Enum.take(args, n_regular)
      extra_args = Enum.drop(args, n_regular)
      padded = positional ++ List.duplicate(:__unset__, max(n_regular - n_args, 0))

      consumed_kwargs =
        MapSet.new(regular_names)
        |> MapSet.intersection(MapSet.new(Map.keys(kwargs)))

      result =
        [regular_names, padded, defaults]
        |> Enum.zip()
        |> Enum.reduce_while({env, ctx}, fn {name, arg, default}, {env, ctx} ->
          cond do
            arg != :__unset__ ->
              {:cont, {Env.put(env, name, arg), ctx}}

            Map.has_key?(kwargs, name) ->
              {:cont, {Env.put(env, name, Map.fetch!(kwargs, name)), ctx}}

            match?({:__evaluated__, _}, default) ->
              {:cont, {Env.put(env, name, elem(default, 1)), ctx}}

            default != nil ->
              {val, _env, ctx} = Interpreter.eval(default, env, ctx)
              {:cont, {Env.put(env, name, val), ctx}}

            true ->
              {:halt, {:exception, "TypeError: missing required argument: '#{name}'", ctx}}
          end
        end)

      case result do
        {:exception, _, _} = err ->
          err

        {env, ctx} ->
          env =
            if has_star,
              do: Env.put(env, star_name(star_param), {:tuple, extra_args}),
              else: env

          consumed_kwonly = MapSet.new(Enum.map(kwonly_params, &elem(&1, 0)))
          consumed_kwargs = MapSet.union(consumed_kwargs, consumed_kwonly)
          extra_kwargs = Map.drop(kwargs, MapSet.to_list(consumed_kwargs))

          extra_kwargs_val =
            if has_dstar, do: PyDict.from_pairs(Enum.to_list(extra_kwargs)), else: extra_kwargs

          env =
            if has_dstar, do: Env.put(env, dstar_name(dstar_param), extra_kwargs_val), else: env

          bind_kwonly(kwonly_params, kwargs, env, ctx)
      end
    end
  end

  @spec bind_kwonly([Parser.param()], map(), Env.t(), Ctx.t()) ::
          {Env.t(), Ctx.t()} | {:exception, String.t(), Ctx.t()}
  defp bind_kwonly([], _kwargs, env, ctx), do: {env, ctx}

  defp bind_kwonly([{name, default} | rest], kwargs, env, ctx) do
    cond do
      Map.has_key?(kwargs, name) ->
        bind_kwonly(rest, kwargs, Env.put(env, name, Map.fetch!(kwargs, name)), ctx)

      match?({:__evaluated__, _}, default) ->
        bind_kwonly(rest, kwargs, Env.put(env, name, elem(default, 1)), ctx)

      default != nil ->
        {val, _env, ctx} = Interpreter.eval(default, env, ctx)
        bind_kwonly(rest, kwargs, Env.put(env, name, val), ctx)

      true ->
        {:exception, "TypeError: missing keyword-only argument: '#{name}'", ctx}
    end
  end

  defp bind_kwonly([{name, default, _type} | rest], kwargs, env, ctx) do
    bind_kwonly([{name, default} | rest], kwargs, env, ctx)
  end

  @doc false
  @spec update_profile_in_result(call_result(), String.t(), float()) :: call_result()
  def update_profile_in_result({val, env, ctx}, name, elapsed_ms) do
    {val, env, profile_record_call(ctx, name, elapsed_ms)}
  end

  def update_profile_in_result({val, env, ctx, extra}, name, elapsed_ms) do
    {val, env, profile_record_call(ctx, name, elapsed_ms), extra}
  end

  @doc false
  @spec decrement_depth(call_result()) :: call_result()
  def decrement_depth({{:exception, _} = signal, env, ctx}),
    do: {signal, env, %{ctx | call_depth: ctx.call_depth - 1}}

  def decrement_depth({val, env, ctx, updated_func}),
    do: {val, env, %{ctx | call_depth: ctx.call_depth - 1}, updated_func}

  def decrement_depth({val, env, ctx}),
    do: {val, env, %{ctx | call_depth: ctx.call_depth - 1}}

  @spec split_variadic_params([Parser.param()]) ::
          {[Parser.param()], Parser.param() | nil, [Parser.param()], Parser.param() | nil}
  defp split_variadic_params(params) do
    # Strip any positional-only separator `/`; callers don't need the
    # marker after we've extracted the position count (which the bind
    # path uses to reject kwarg forms for positional-only names).
    params = Enum.reject(params, fn p -> elem(p, 0) == "/" end)

    {regular_rev, star, kwonly_rev, dstar} =
      Enum.reduce(params, {[], nil, [], nil}, fn param, {regular, star, kwonly, dstar} ->
        name = elem(param, 0)

        cond do
          String.starts_with?(name, "**") ->
            {regular, star, kwonly, param}

          name == "*" ->
            {regular, :kwonly_sep, kwonly, dstar}

          String.starts_with?(name, "*") ->
            {regular, param, kwonly, dstar}

          star != nil ->
            {regular, star, [param | kwonly], dstar}

          true ->
            {[param | regular], star, kwonly, dstar}
        end
      end)

    real_star = if star == :kwonly_sep, do: nil, else: star
    {Enum.reverse(regular_rev), real_star, Enum.reverse(kwonly_rev), dstar}
  end

  @spec star_name(Parser.param()) :: String.t()
  defp star_name(param), do: String.trim_leading(elem(param, 0), "*")

  @spec dstar_name(Parser.param()) :: String.t()
  defp dstar_name(param), do: String.trim_leading(elem(param, 0), "*")

  @spec profile_record_call(Ctx.t(), String.t(), float()) :: Ctx.t()
  defp profile_record_call(%Ctx{profile: nil} = ctx, _name, _elapsed_ms), do: ctx

  defp profile_record_call(%Ctx{profile: profile} = ctx, name, elapsed_ms) do
    call_counts = Map.update(profile.call_counts, name, 1, &(&1 + 1))
    call = Map.update(profile.call, name, elapsed_ms, &(&1 + elapsed_ms))
    %{ctx | profile: %{profile | call_counts: call_counts, call: call}}
  end
end
