defmodule Pyex.Stdlib.Inspect do
  @moduledoc """
  Python `inspect` module — the reflection helpers that have meaning over
  pyex's value model: the `is*` predicates and `signature`.

  Frame/source introspection (`getsource`, `currentframe`, `stack`) has no
  faithful analogue in the sandbox and is intentionally omitted.
  """

  @behaviour Pyex.Stdlib.Module

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "__name__" => "inspect",
      "isfunction" => {:builtin, &pred_function/1},
      "ismethod" => {:builtin, &pred_method/1},
      "isclass" => {:builtin, &pred_class/1},
      "isbuiltin" => {:builtin, &pred_builtin/1},
      "isroutine" => {:builtin, &pred_routine/1},
      "ismodule" => {:builtin, &pred_module/1},
      "isgeneratorfunction" => {:builtin, &pred_generator_function/1},
      "signature" => {:builtin, &signature/1}
    }
  end

  @spec pred_function([Pyex.Interpreter.pyvalue()]) :: boolean()
  defp pred_function([{:function, _, _, _, _, _, _}]), do: true
  defp pred_function([{:func_with_attrs, _, _}]), do: true
  defp pred_function([{:lru_cached_function, _, _}]), do: true
  defp pred_function([_]), do: false

  defp pred_method([{:bound_method, _, _}]), do: true
  defp pred_method([{:bound_method, _, _, _}]), do: true
  defp pred_method([_]), do: false

  defp pred_class([{:class, _, _, _}]), do: true
  defp pred_class([{:builtin_type, _, _}]), do: true
  defp pred_class([{:exception_class, _}]), do: true
  defp pred_class([_]), do: false

  defp pred_builtin([{:builtin, _}]), do: true
  defp pred_builtin([{:builtin_kw, _}]), do: true
  defp pred_builtin([{:builtin_type, _, _}]), do: true
  defp pred_builtin([_]), do: false

  defp pred_routine([f]), do: pred_function([f]) or pred_method([f]) or pred_builtin([f])

  defp pred_module([{:module, _, _}]), do: true
  defp pred_module([_]), do: false

  defp pred_generator_function([{:function, _, _, _, _, is_gen, _}]), do: is_gen == true
  defp pred_generator_function([{:func_with_attrs, func, _}]), do: pred_generator_function([func])
  defp pred_generator_function([_]), do: false

  # inspect.signature(f) — a Signature object whose str() is "(a, b=2, *args)".
  @spec signature([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp signature([{:func_with_attrs, func, _}]), do: signature([func])

  defp signature([{:function, _name, params, _body, _env, _gen, _kind}]) do
    signature_object(render_params(params))
  end

  defp signature([_other]),
    do: {:exception, "TypeError: signature() argument is not a callable with a signature"}

  @spec signature_object(String.t()) :: Pyex.Interpreter.pyvalue()
  defp signature_object(sig_str) do
    {:instance,
     {:class, "Signature", [],
      %{
        "__name__" => "Signature",
        "__str__" => {:builtin, fn [_self] -> sig_str end},
        "__repr__" => {:builtin, fn [_self] -> "<Signature #{sig_str}>" end}
      }}, %{"__sig_str__" => sig_str}}
  end

  @spec render_params([Pyex.Parser.param()]) :: String.t()
  defp render_params(params) do
    "(" <> Enum.map_join(params, ", ", &render_param/1) <> ")"
  end

  defp render_param({name, default}), do: render_named(name, default)
  defp render_param({name, default, _type}), do: render_named(name, default)
  defp render_param(name) when is_binary(name), do: name
  defp render_param(_), do: ""

  defp render_named(name, _default) when name in ["*", "/"], do: name
  defp render_named(name, nil), do: name
  defp render_named(name, {:__evaluated__, value}), do: "#{name}=#{default_repr(value)}"
  defp render_named(name, _other), do: name <> "=..."

  defp default_repr(value), do: Pyex.Builtins.py_repr_quoted(value)
end
