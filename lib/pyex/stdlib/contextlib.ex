defmodule Pyex.Stdlib.Contextlib do
  @moduledoc """
  Python `contextlib` module.

  Provides `contextmanager`, `suppress`, `nullcontext`, and `closing`.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Interpreter

  @doc """
  Returns the module value map.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "contextmanager" => {:builtin, &contextmanager/1},
      "suppress" => {:builtin, &suppress/1},
      "nullcontext" => {:builtin, &nullcontext/1},
      "closing" => {:builtin, &closing/1},
      "ExitStack" => {:builtin, &exit_stack/1}
    }
  end

  @doc false
  @spec contextmanager([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def contextmanager([func]) do
    # Returns a wrapper that, when called with the same args as func,
    # produces a _GeneratorContextManager instance.
    {:builtin,
     fn args ->
       {:ctx_call,
        fn env, ctx ->
          # Call the generator function in deferred mode so it pauses at yield
          defer_ctx = %{ctx | generator_mode: :defer}

          case Interpreter.call_function(func, args, %{}, env, defer_ctx) do
            {{:exception, _} = exc, env, ctx} ->
              {exc, env, %{ctx | generator_mode: nil}}

            {gen, env, gen_ctx} ->
              cm_instance = make_generator_cm(gen)
              {cm_instance, env, %{gen_ctx | generator_mode: nil}}
          end
        end}
     end}
  end

  def contextmanager(_), do: {:exception, "TypeError: contextmanager() takes 1 argument"}

  @spec make_generator_cm(Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp make_generator_cm(gen) do
    {:instance,
     {:class, "_GeneratorContextManager", [],
      %{
        "__gen__" => gen,
        "__name__" => "_GeneratorContextManager"
      }}, %{"__gen__" => gen}}
  end

  @doc false
  @spec suppress([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def suppress(exception_types) do
    {:instance,
     {:class, "suppress", [],
      %{
        "__name__" => "suppress",
        "__suppress_types__" => {:tuple, exception_types}
      }}, %{"__types__" => {:tuple, exception_types}}}
  end

  @doc false
  @spec nullcontext([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def nullcontext([]) do
    {:instance, {:class, "nullcontext", [], %{"__name__" => "nullcontext"}},
     %{"__enter_val__" => nil}}
  end

  def nullcontext([enter_result]) do
    {:instance, {:class, "nullcontext", [], %{"__name__" => "nullcontext"}},
     %{"__enter_val__" => enter_result}}
  end

  @doc false
  @spec closing([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def closing([thing]) do
    {:instance, {:class, "closing", [], %{"__name__" => "closing"}}, %{"__thing__" => thing}}
  end

  def closing(_), do: {:exception, "TypeError: closing() takes 1 argument"}

  @doc false
  @spec exit_stack([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def exit_stack(_) do
    {:instance, {:class, "ExitStack", [], %{"__name__" => "ExitStack"}}, %{"__stack__" => []}}
  end
end
