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

  ## Defaults

  Resource ceilings are **on by default** — a caller who runs
  untrusted code with no `:limits` still gets a compute, memory,
  and output budget:

  | field              | default      | meaning                          |
  | ------------------ | ------------ | -------------------------------- |
  | `timeout`          | `:infinity`  | wall-clock budget (opt-in)       |
  | `max_steps`        | `10_000_000` | interpreter step budget          |
  | `max_memory_bytes` | `50_000_000` | cumulative allocation budget     |
  | `max_output_bytes` | `1_000_000`  | total captured output            |

  An unspecified field takes its safe default, so partial limits
  are *additive* — `limits: [max_steps: 1_000]` still enforces the
  default 50 MB / 1 MB memory and output ceilings. To lift a single
  ceiling, set it to `:infinity` explicitly; to lift all of them,
  pass `limits: :none` (see `unbounded/0`), which also restores the
  no-budget fast path in `Pyex.Ctx.check_step/1`.

  `max_memory_bytes` is a *cumulative* allocation budget, not a peak
  live-heap measurement: an allocate-and-discard loop accrues against
  it even when little memory is retained.

  This struct is configuration only — no mutable counters. The
  interpreter tracks usage internally in `Pyex.Ctx`.
  """

  @type t :: %__MODULE__{
          timeout: pos_integer() | :infinity,
          max_steps: pos_integer() | :infinity,
          max_memory_bytes: pos_integer() | :infinity,
          max_output_bytes: pos_integer() | :infinity
        }

  @default_max_steps 10_000_000
  @default_max_memory_bytes 50_000_000
  @default_max_output_bytes 1_000_000

  defstruct timeout: :infinity,
            max_steps: @default_max_steps,
            max_memory_bytes: @default_max_memory_bytes,
            max_output_bytes: @default_max_output_bytes

  @doc """
  Creates a `Limits` struct from a keyword list.

  Unspecified fields take their safe defaults (see the module doc).
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

  @doc """
  Returns a `Limits` struct with every ceiling lifted (`:infinity`).

  This is the escape hatch for trusted code that needs unbounded
  compute. With no timeout and all ceilings at `:infinity`, the
  interpreter takes the no-budget fast path in
  `Pyex.Ctx.check_step/1`.
  """
  @spec unbounded() :: t()
  def unbounded do
    %__MODULE__{
      timeout: :infinity,
      max_steps: :infinity,
      max_memory_bytes: :infinity,
      max_output_bytes: :infinity
    }
  end
end
