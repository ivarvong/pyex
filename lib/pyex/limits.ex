defmodule Pyex.Limits do
  @moduledoc """
  Configuration for interpreter resource ceilings.

  Passed via the `:limits` option to `Pyex.run/2`:

      Pyex.run(source, limits: [
        timeout: 5_000,
        max_steps: 1_000_000,
        max_memory_bytes: 50_000_000,
        max_output_bytes: 1_000_000
      ])

  All fields default to `:infinity` (no limit). This struct is
  configuration only — no mutable counters. The interpreter
  tracks usage internally in `Pyex.Ctx`.
  """

  @type t :: %__MODULE__{
          timeout: pos_integer() | :infinity,
          max_steps: pos_integer() | :infinity,
          max_memory_bytes: pos_integer() | :infinity,
          max_output_bytes: pos_integer() | :infinity
        }

  defstruct timeout: :infinity,
            max_steps: :infinity,
            max_memory_bytes: :infinity,
            max_output_bytes: :infinity

  @doc """
  Creates a `Limits` struct from a keyword list.

  Raises `ArgumentError` on unknown keys.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    valid_keys = [:timeout, :max_steps, :max_memory_bytes, :max_output_bytes]
    unknown = Keyword.keys(opts) -- valid_keys

    if unknown != [] do
      raise ArgumentError,
            "unknown limit options #{inspect(unknown)}. Valid: #{inspect(valid_keys)}"
    end

    struct!(__MODULE__, opts)
  end
end
