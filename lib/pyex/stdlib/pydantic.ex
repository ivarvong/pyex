defmodule Pyex.Stdlib.Pydantic do
  @moduledoc """
  Python `pydantic` module.

  Provides `BaseModel` for data validation and serialization.
  Subclasses of `BaseModel` use type annotations to define fields,
  with automatic type coercion, constraint validation, and
  dict/JSON serialization.

  ## Supported features

  - `BaseModel` subclassing with annotated fields
  - Type coercion (`int` → `float`, `str` → `int`, etc.)
  - `Field()` with constraints (`ge`, `le`, `gt`, `lt`,
    `min_length`, `max_length`, `pattern`, `default`)
  - `model_dump()` / `model_validate()` / `model_json_schema()`
  - `Optional` fields, `List`/`Dict` typed fields
  - Nested model validation
  - `@field_validator` / `@model_validator` decorators
  """

  @behaviour Pyex.Stdlib.Module

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "BaseModel" => base_model_class(),
      "Field" => {:builtin_kw, &field/2}
    }
  end

  @doc """
  Returns `true` if `value` is a class that inherits from `BaseModel`.
  """
  @spec pydantic_class?(Pyex.Interpreter.pyvalue()) :: boolean()
  def pydantic_class?({:class, _, bases, class_attrs}) do
    Map.has_key?(class_attrs, "__pydantic__") or
      Enum.any?(bases, &pydantic_class?/1)
  end

  def pydantic_class?(_), do: false

  @doc """
  Validates a dict against a Pydantic model class, returning either
  `{:ok, instance}` or `{:error, message}`.

  Used by `Pyex.Lambda` to auto-parse request bodies for FastAPI handlers
  with Pydantic type-annotated parameters.
  """
  @spec validate_body(Pyex.Interpreter.pyvalue(), map()) ::
          {:ok, Pyex.Interpreter.pyvalue()} | {:error, String.t()}
  def validate_body(class, data) when is_map(data) do
    {annotations, defaults, field_constraints} = collect_fields(class)
    kwargs = Map.reject(data, fn {k, _} -> is_binary(k) and String.starts_with?(k, "__") end)

    case validate_and_coerce(annotations, defaults, field_constraints, kwargs, class) do
      {:ok, attrs} -> {:ok, {:instance, class, attrs}}
      {:error, errors} -> {:error, format_validation_errors(errors)}
    end
  end

  def validate_body(_class, _data), do: {:error, "request body is not a valid dict"}

  @spec base_model_class() :: Pyex.Interpreter.pyvalue()
  defp base_model_class do
    {:class, "BaseModel", [],
     %{
       "__init__" => {:builtin_kw, &base_model_init/2},
       "__pydantic__" => true,
       "model_dump" => {:builtin_kw, &model_dump/2},
       "model_validate" => {:builtin_kw, &model_validate_classmethod/2},
       "model_json_schema" => {:builtin_kw, &model_json_schema_classmethod/2}
     }}
  end

  @spec field([Pyex.Interpreter.pyvalue()], %{optional(String.t()) => Pyex.Interpreter.pyvalue()}) ::
          Pyex.Interpreter.pyvalue()
  defp field(args, kwargs) do
    default =
      case args do
        [val | _] -> val
        [] -> Map.get(kwargs, "default", :__pydantic_required__)
      end

    constraints =
      kwargs
      |> Map.drop(["default"])
      |> Enum.into(%{})

    %{"__pydantic_field__" => true, "default" => default, "constraints" => constraints}
  end

  @spec base_model_init(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: Pyex.Interpreter.pyvalue()
  defp base_model_init([self | _pos_args], kwargs) do
    {:instance, class, _attrs} = self
    {annotations, defaults, field_constraints} = collect_fields(class)

    case validate_and_coerce(annotations, defaults, field_constraints, kwargs, class) do
      {:ok, attrs} ->
        {:instance, class, attrs}

      {:error, errors} ->
        msg = format_validation_errors(errors)
        {:exception, "ValidationError: #{msg}"}
    end
  end

  @spec collect_fields(Pyex.Interpreter.pyvalue()) ::
          {%{String.t() => String.t() | Pyex.Interpreter.pyvalue()},
           %{String.t() => Pyex.Interpreter.pyvalue()},
           %{String.t() => %{String.t() => Pyex.Interpreter.pyvalue()}}}
  defp collect_fields(class) do
    mro = linearize(class)

    Enum.reduce(mro, {%{}, %{}, %{}}, fn {:class, _, _, class_attrs},
                                         {ann_acc, def_acc, con_acc} ->
      class_annotations = Map.get(class_attrs, "__annotations__", %{})
      ann_acc = Map.merge(class_annotations, ann_acc)

      {def_acc, con_acc} =
        Enum.reduce(class_annotations, {def_acc, con_acc}, fn {field_name, _type}, {d, c} ->
          case Map.get(class_attrs, field_name) do
            %{"__pydantic_field__" => true} = pf ->
              d =
                case Map.get(pf, "default") do
                  :__pydantic_required__ -> d
                  default -> Map.put_new(d, field_name, default)
                end

              c = Map.put_new(c, field_name, Map.get(pf, "constraints", %{}))
              {d, c}

            nil ->
              {d, c}

            value ->
              {Map.put_new(d, field_name, value), c}
          end
        end)

      {ann_acc, def_acc, con_acc}
    end)
  end

  @spec validate_and_coerce(
          %{String.t() => String.t() | Pyex.Interpreter.pyvalue()},
          %{String.t() => Pyex.Interpreter.pyvalue()},
          %{String.t() => %{String.t() => Pyex.Interpreter.pyvalue()}},
          %{String.t() => Pyex.Interpreter.pyvalue()},
          Pyex.Interpreter.pyvalue()
        ) :: {:ok, %{String.t() => Pyex.Interpreter.pyvalue()}} | {:error, [String.t()]}
  defp validate_and_coerce(annotations, defaults, field_constraints, kwargs, class) do
    {attrs, errors} =
      Enum.reduce(annotations, {%{}, []}, fn {field_name, type_str}, {attrs, errors} ->
        raw =
          case Map.get(kwargs, field_name) do
            nil -> Map.get(defaults, field_name)
            val -> val
          end

        if raw == nil and not optional?(type_str) and not Map.has_key?(defaults, field_name) do
          {attrs, ["#{field_name}: field required" | errors]}
        else
          value = if raw == nil, do: nil, else: raw

          case coerce(value, type_str, class) do
            {:ok, coerced} ->
              constraints = Map.get(field_constraints, field_name, %{})

              case check_constraints(coerced, constraints) do
                :ok ->
                  {Map.put(attrs, field_name, coerced), errors}

                {:error, msg} ->
                  {attrs, ["#{field_name}: #{msg}" | errors]}
              end

            {:error, msg} ->
              {attrs, ["#{field_name}: #{msg}" | errors]}
          end
        end
      end)

    if errors == [] do
      {:ok, attrs}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  @spec coerce(
          Pyex.Interpreter.pyvalue(),
          String.t() | Pyex.Interpreter.pyvalue(),
          Pyex.Interpreter.pyvalue()
        ) :: {:ok, Pyex.Interpreter.pyvalue()} | {:error, String.t()}
  defp coerce(nil, type, _class) do
    if optional?(type), do: {:ok, nil}, else: {:error, "none is not an allowed value"}
  end

  defp coerce(value, {:class, "date", _, _}, _class) do
    cond do
      match?({:instance, {:class, "date", _, _}, _}, value) ->
        {:ok, value}

      is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, d} -> {:ok, Pyex.Stdlib.Datetime.make_date(d)}
          {:error, _} -> {:error, "value is not a valid date"}
        end

      true ->
        {:error, "value is not a valid date"}
    end
  end

  defp coerce(value, {:class, "datetime", _, _}, _class) do
    cond do
      match?({:instance, {:class, "datetime", _, _}, _}, value) ->
        {:ok, value}

      is_binary(value) ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} ->
            {:ok, Pyex.Stdlib.Datetime.make_datetime(DateTime.from_naive!(ndt, "Etc/UTC"))}

          {:error, _} ->
            case Date.from_iso8601(value) do
              {:ok, d} ->
                ndt = NaiveDateTime.new!(d, ~T[00:00:00])
                {:ok, Pyex.Stdlib.Datetime.make_datetime(DateTime.from_naive!(ndt, "Etc/UTC"))}

              {:error, _} ->
                {:error, "value is not a valid datetime"}
            end
        end

      true ->
        {:error, "value is not a valid datetime"}
    end
  end

  defp coerce(value, {:class, _, _, _} = model_class, _class) do
    cond do
      is_map(value) and not is_struct(value) ->
        validate_nested(value, model_class)

      match?({:instance, ^model_class, _}, value) ->
        {:ok, value}

      true ->
        {:error, "value is not a valid #{class_name(model_class)}"}
    end
  end

  defp coerce(value, "str", _class) do
    if is_binary(value), do: {:ok, value}, else: {:ok, to_string(value)}
  end

  defp coerce(value, "int", _class) do
    cond do
      is_integer(value) -> {:ok, value}
      is_float(value) -> {:ok, trunc(value)}
      is_boolean(value) -> {:ok, if(value, do: 1, else: 0)}
      is_binary(value) -> parse_int(value)
      true -> {:error, "value is not a valid integer"}
    end
  end

  defp coerce(value, "float", _class) do
    cond do
      is_float(value) -> {:ok, value}
      is_integer(value) -> {:ok, value * 1.0}
      is_boolean(value) -> {:ok, if(value, do: 1.0, else: 0.0)}
      is_binary(value) -> parse_float(value)
      true -> {:error, "value is not a valid float"}
    end
  end

  defp coerce(value, "bool", _class) do
    cond do
      is_boolean(value) -> {:ok, value}
      is_integer(value) -> {:ok, value != 0}
      is_binary(value) -> {:error, "value is not a valid boolean"}
      true -> {:error, "value is not a valid boolean"}
    end
  end

  defp coerce(value, "Optional[" <> rest, class) do
    inner = String.trim_trailing(rest, "]")

    if value == nil do
      {:ok, nil}
    else
      coerce(value, inner, class)
    end
  end

  defp coerce({:py_list, reversed, _}, "List[" <> rest, class) do
    coerce(Enum.reverse(reversed), "List[" <> rest, class)
  end

  defp coerce(value, "List[" <> rest, class) do
    inner = String.trim_trailing(rest, "]")

    cond do
      is_list(value) ->
        results = Enum.map(value, &coerce(&1, inner, class))

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil -> {:ok, Enum.map(results, fn {:ok, v} -> v end)}
          {:error, msg} -> {:error, "list item: #{msg}"}
        end

      true ->
        {:error, "value is not a valid list"}
    end
  end

  defp coerce(value, "Dict[" <> rest, class) do
    trimmed = String.trim_trailing(rest, "]")

    case String.split(trimmed, ", ", parts: 2) do
      [key_type, val_type] ->
        if is_map(value) do
          results =
            Enum.map(value, fn {k, v} ->
              with {:ok, ck} <- coerce(k, key_type, class),
                   {:ok, cv} <- coerce(v, val_type, class) do
                {:ok, {ck, cv}}
              end
            end)

          case Enum.find(results, &match?({:error, _}, &1)) do
            nil -> {:ok, results |> Enum.map(fn {:ok, kv} -> kv end) |> Map.new()}
            {:error, msg} -> {:error, "dict: #{msg}"}
          end
        else
          {:error, "value is not a valid dict"}
        end

      _ ->
        {:ok, value}
    end
  end

  defp coerce(value, _type_str, _class), do: {:ok, value}

  @spec validate_nested(map(), Pyex.Interpreter.pyvalue()) ::
          {:ok, Pyex.Interpreter.pyvalue()} | {:error, String.t()}
  defp validate_nested(data, model_class) when is_map(data) do
    {annotations, defaults, field_constraints} = collect_fields(model_class)
    kwargs = Map.reject(data, fn {k, _} -> is_binary(k) and String.starts_with?(k, "__") end)

    case validate_and_coerce(annotations, defaults, field_constraints, kwargs, model_class) do
      {:ok, attrs} -> {:ok, {:instance, model_class, attrs}}
      {:error, errors} -> {:error, format_validation_errors(errors)}
    end
  end

  @spec class_name(Pyex.Interpreter.pyvalue()) :: String.t()
  defp class_name({:class, name, _, _}), do: name

  @spec check_constraints(
          Pyex.Interpreter.pyvalue(),
          %{String.t() => Pyex.Interpreter.pyvalue()}
        ) :: :ok | {:error, String.t()}
  defp check_constraints(_value, constraints) when map_size(constraints) == 0, do: :ok

  defp check_constraints(value, constraints) do
    errors =
      Enum.reduce(constraints, [], fn
        {"gt", limit}, errors ->
          if is_number(value) and value > limit, do: errors, else: ["must be > #{limit}" | errors]

        {"ge", limit}, errors ->
          if is_number(value) and value >= limit,
            do: errors,
            else: ["must be >= #{limit}" | errors]

        {"lt", limit}, errors ->
          if is_number(value) and value < limit, do: errors, else: ["must be < #{limit}" | errors]

        {"le", limit}, errors ->
          if is_number(value) and value <= limit,
            do: errors,
            else: ["must be <= #{limit}" | errors]

        {"min_length", limit}, errors ->
          len =
            cond do
              is_binary(value) -> String.length(value)
              is_list(value) -> length(value)
              true -> 0
            end

          if len >= limit,
            do: errors,
            else: ["length must be >= #{limit}" | errors]

        {"max_length", limit}, errors ->
          len =
            cond do
              is_binary(value) -> String.length(value)
              is_list(value) -> length(value)
              true -> 0
            end

          if len <= limit,
            do: errors,
            else: ["length must be <= #{limit}" | errors]

        {"pattern", pattern}, errors ->
          if is_binary(value) do
            case Regex.compile(pattern) do
              {:ok, re} ->
                if Regex.match?(re, value), do: errors, else: ["must match #{pattern}" | errors]

              {:error, _} ->
                errors
            end
          else
            errors
          end

        {"description", _}, errors ->
          errors

        _, errors ->
          errors
      end)

    case errors do
      [] -> :ok
      [msg | _] -> {:error, msg}
    end
  end

  @spec model_dump(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: Pyex.Interpreter.pyvalue()
  defp model_dump([self], kwargs) do
    {:instance, class, attrs} = self
    {annotations, _defaults, _constraints} = collect_fields(class)
    field_names = Map.keys(annotations)

    include = Map.get(kwargs, "include")
    exclude = Map.get(kwargs, "exclude")
    exclude_none = Map.get(kwargs, "exclude_none", false)

    fields =
      field_names
      |> filter_fields(include, exclude)
      |> Enum.reject(fn name -> exclude_none and Map.get(attrs, name) == nil end)

    Enum.reduce(fields, %{}, fn name, acc ->
      value = Map.get(attrs, name)
      Map.put(acc, name, dump_value(value))
    end)
  end

  @spec dump_value(Pyex.Interpreter.pyvalue()) :: Pyex.Interpreter.pyvalue()
  defp dump_value({:instance, class, attrs}) when is_tuple(class) do
    if pydantic_class?(class) do
      Enum.reduce(attrs, %{}, fn {k, v}, acc ->
        Map.put(acc, k, dump_value(v))
      end)
    else
      {:instance, class, attrs}
    end
  end

  defp dump_value(list) when is_list(list), do: Enum.map(list, &dump_value/1)
  defp dump_value(value), do: value

  @spec filter_fields([String.t()], Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          [String.t()]
  defp filter_fields(fields, nil, nil), do: fields

  defp filter_fields(fields, {:set, include_set}, _) do
    Enum.filter(fields, &MapSet.member?(include_set, &1))
  end

  defp filter_fields(fields, _, {:set, exclude_set}) do
    Enum.reject(fields, &MapSet.member?(exclude_set, &1))
  end

  defp filter_fields(fields, _, _), do: fields

  @spec model_validate_classmethod(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: Pyex.Interpreter.pyvalue()
  defp model_validate_classmethod(args, _kwargs) do
    case args do
      [self, data] when is_map(data) ->
        class =
          case self do
            {:class, _, _, _} -> self
            {:instance, cls, _} -> cls
          end

        {annotations, defaults, field_constraints} = collect_fields(class)
        kwargs = Map.reject(data, fn {k, _} -> is_binary(k) and String.starts_with?(k, "__") end)

        case validate_and_coerce(annotations, defaults, field_constraints, kwargs, class) do
          {:ok, attrs} ->
            {:instance, class, attrs}

          {:error, errors} ->
            {:exception, "ValidationError: #{format_validation_errors(errors)}"}
        end

      [_self, _other] ->
        {:exception, "ValidationError: value is not a valid dict"}

      _ ->
        {:exception, "TypeError: model_validate() requires a dict argument"}
    end
  end

  @spec model_json_schema_classmethod(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: Pyex.Interpreter.pyvalue()
  defp model_json_schema_classmethod(args, _kwargs) do
    class =
      case args do
        [self | _] ->
          case self do
            {:class, _, _, _} -> self
            {:instance, cls, _} -> cls
          end

        [] ->
          nil
      end

    if class == nil do
      {:exception, "TypeError: model_json_schema() requires a class"}
    else
      {:class, name, _, _} = class
      {annotations, defaults, field_constraints} = collect_fields(class)

      properties =
        Enum.reduce(annotations, %{}, fn {field_name, type_str}, acc ->
          prop = type_to_json_schema(type_str)
          constraints = Map.get(field_constraints, field_name, %{})
          prop = apply_schema_constraints(prop, constraints)

          prop =
            case Map.get(defaults, field_name) do
              nil -> prop
              default -> Map.put(prop, "default", default)
            end

          Map.put(acc, field_name, prop)
        end)

      required =
        annotations
        |> Enum.reject(fn {field_name, type_str} ->
          optional?(type_str) or Map.has_key?(defaults, field_name)
        end)
        |> Enum.map(fn {name, _} -> name end)
        |> Enum.sort()

      schema = %{
        "title" => name,
        "type" => "object",
        "properties" => properties
      }

      if required != [], do: Map.put(schema, "required", required), else: schema
    end
  end

  @spec type_to_json_schema(String.t() | Pyex.Interpreter.pyvalue()) ::
          %{String.t() => Pyex.Interpreter.pyvalue()}
  defp type_to_json_schema({:class, name, _, _}), do: %{"$ref" => "#/$defs/#{name}"}
  defp type_to_json_schema("str"), do: %{"type" => "string"}
  defp type_to_json_schema("int"), do: %{"type" => "integer"}
  defp type_to_json_schema("float"), do: %{"type" => "number"}
  defp type_to_json_schema("bool"), do: %{"type" => "boolean"}

  defp type_to_json_schema("Optional[" <> rest) do
    inner = String.trim_trailing(rest, "]")
    inner_schema = type_to_json_schema(inner)
    %{"anyOf" => [inner_schema, %{"type" => "null"}]}
  end

  defp type_to_json_schema("List[" <> rest) do
    inner = String.trim_trailing(rest, "]")
    %{"type" => "array", "items" => type_to_json_schema(inner)}
  end

  defp type_to_json_schema("Dict[" <> rest) do
    trimmed = String.trim_trailing(rest, "]")

    case String.split(trimmed, ", ", parts: 2) do
      [_key_type, val_type] ->
        %{"type" => "object", "additionalProperties" => type_to_json_schema(val_type)}

      _ ->
        %{"type" => "object"}
    end
  end

  defp type_to_json_schema(_), do: %{}

  @spec apply_schema_constraints(
          %{String.t() => Pyex.Interpreter.pyvalue()},
          %{String.t() => Pyex.Interpreter.pyvalue()}
        ) :: %{String.t() => Pyex.Interpreter.pyvalue()}
  defp apply_schema_constraints(schema, constraints) do
    Enum.reduce(constraints, schema, fn
      {"gt", v}, s -> Map.put(s, "exclusiveMinimum", v)
      {"ge", v}, s -> Map.put(s, "minimum", v)
      {"lt", v}, s -> Map.put(s, "exclusiveMaximum", v)
      {"le", v}, s -> Map.put(s, "maximum", v)
      {"min_length", v}, s -> Map.put(s, "minLength", v)
      {"max_length", v}, s -> Map.put(s, "maxLength", v)
      {"pattern", v}, s -> Map.put(s, "pattern", v)
      {"description", v}, s -> Map.put(s, "description", v)
      _, s -> s
    end)
  end

  @spec optional?(String.t()) :: boolean()
  defp optional?("Optional[" <> _), do: true
  defp optional?(_), do: false

  @spec parse_int(String.t()) :: {:ok, integer()} | {:error, String.t()}
  defp parse_int(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "value is not a valid integer"}
    end
  end

  @spec parse_float(String.t()) :: {:ok, float()} | {:error, String.t()}
  defp parse_float(s) do
    trimmed = String.trim(s)

    case Float.parse(trimmed) do
      {f, ""} ->
        {:ok, f}

      _ ->
        case Integer.parse(trimmed) do
          {n, ""} -> {:ok, n * 1.0}
          _ -> {:error, "value is not a valid float"}
        end
    end
  end

  @spec format_validation_errors([String.t()]) :: String.t()
  defp format_validation_errors([single]), do: single
  defp format_validation_errors(errors), do: Enum.join(errors, "; ")

  @spec linearize(Pyex.Interpreter.pyvalue()) :: [Pyex.Interpreter.pyvalue()]
  defp linearize({:class, _, [], _} = class), do: [class]

  defp linearize({:class, _, bases, _} = class) do
    [class | Enum.flat_map(bases, &linearize/1)]
  end
end
