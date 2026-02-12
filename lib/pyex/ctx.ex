defmodule Pyex.Ctx do
  @moduledoc """
  Execution context for the Pyex interpreter.

  Implements Temporal-style deterministic replay. Every
  non-deterministic decision (branch taken, loop iteration,
  side effect result) is recorded as an event in an append-only
  log. On replay, the interpreter consumes events from the log
  instead of re-executing, allowing instant resume from any
  point in history.

  Modes:
  - `:live` -- executing normally, recording events
  - `:replay` -- consuming previously recorded events, then
    switching to `:live` when the log is exhausted

  The context is threaded through every `eval` call alongside
  the environment.
  """

  @type event_type ::
          :assign
          | :branch
          | :loop_iter
          | :call_enter
          | :call_exit
          | :side_effect
          | :suspend
          | :exception
          | :file_op
          | :output

  @type event :: {event_type(), non_neg_integer(), term()}

  @type mode :: :live | :replay | :noop

  @type file_handle :: %{
          path: String.t(),
          mode: :read | :write | :append,
          buffer: String.t()
        }

  @type profile_data :: %{
          line_counts: %{optional(pos_integer()) => pos_integer()},
          call_counts: %{optional(String.t()) => pos_integer()},
          call_us: %{optional(String.t()) => non_neg_integer()}
        }

  @type network_config :: %{
          allowed_hosts: [String.t()],
          allowed_url_prefixes: [String.t()],
          allowed_methods: [String.t()],
          dangerously_allow_full_internet_access: boolean()
        }

  @type capability :: :boto3 | :sql | atom()

  @type generator_mode :: :accumulate | :defer | :defer_inner | nil

  @type t :: %__MODULE__{
          mode: mode(),
          log: [event()],
          remaining: [event()],
          step: non_neg_integer(),
          filesystem: term(),
          fs_module: module() | nil,
          handles: %{optional(non_neg_integer()) => file_handle()},
          next_handle: non_neg_integer(),
          environ: %{optional(String.t()) => String.t()},
          modules: %{optional(String.t()) => Pyex.Stdlib.Module.module_value()},
          imported_modules: %{optional(String.t()) => Pyex.Stdlib.Module.module_value()},
          timeout_ns: non_neg_integer() | nil,
          compute_ns: non_neg_integer(),
          compute_started_at: integer() | nil,
          profile: profile_data() | nil,
          generator_mode: generator_mode(),
          generator_acc: [term()] | nil,
          iterators: %{optional(non_neg_integer()) => [term()] | term()},
          next_iterator_id: non_neg_integer(),
          network: network_config() | nil,
          capabilities: MapSet.t(capability()),
          exception_instance: term(),
          current_line: non_neg_integer() | nil,
          call_depth: non_neg_integer(),
          max_call_depth: non_neg_integer()
        }

  defstruct mode: :live,
            log: [],
            remaining: [],
            step: 0,
            filesystem: nil,
            fs_module: nil,
            handles: %{},
            next_handle: 0,
            environ: %{},
            modules: %{},
            imported_modules: %{},
            timeout_ns: nil,
            compute_ns: 0,
            compute_started_at: nil,
            profile: nil,
            generator_mode: nil,
            generator_acc: nil,
            iterators: %{},
            next_iterator_id: 0,
            network: nil,
            capabilities: MapSet.new(),
            exception_instance: nil,
            current_line: nil,
            call_depth: 0,
            max_call_depth: 500

  @doc """
  Creates a fresh live context that records all events.

  Options:
  - `:filesystem` -- a filesystem backend struct (e.g. `Pyex.Filesystem.Memory.new()`)
  - `:fs_module` -- the module implementing `Pyex.Filesystem` behaviour
  - `:environ` -- a map of environment variables accessible via `os.environ`
  - `:modules` -- custom Python modules available via `import`. A map from
    module name strings to either a `%{String.t() => pyvalue()}` map or a
    module implementing `Pyex.Stdlib.Module`.
  - `:timeout_ms` -- maximum *compute* time in milliseconds (nil = no limit).
    I/O time (HTTP requests, SQL queries) does not count against the budget.
  - `:profile` -- when `true`, collects per-line execution counts and
    per-function call counts with timing. Results are stored in the
    returned context's `profile` field. Default `false`.
  - `:network` -- network access policy for the `requests` module.
    A keyword list or map with:
    - `:allowed_hosts` -- list of hostnames that are permitted (exact match,
      compared against `URI.parse(url).host`)
    - `:allowed_url_prefixes` -- list of URL prefixes that are permitted
      (use trailing slash to prevent subdomain bypass)
    - `:allowed_methods` -- list of HTTP methods allowed (default `["GET", "HEAD"]`)
    - `:dangerously_allow_full_internet_access` -- `true` to allow all
      URLs and methods (use with caution)

    A request is allowed if its URL matches any `:allowed_hosts` entry
    **or** any `:allowed_url_prefixes` entry. When `nil` (the default),
    all network access is denied.
  - `:capabilities` -- a list of atoms naming enabled I/O capabilities.
    Known capabilities: `:boto3` (S3 operations), `:sql` (database
    queries). All capabilities are denied by default.
  - `:boto3` -- shorthand for adding `:boto3` to capabilities.
  - `:sql` -- shorthand for adding `:sql` to capabilities.
  """
  @valid_keys [
    :filesystem,
    :fs_module,
    :environ,
    :modules,
    :timeout_ms,
    :profile,
    :network,
    :capabilities,
    :boto3,
    :sql
  ]

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    unknown = Keyword.keys(opts) -- @valid_keys

    if unknown != [] do
      raise ArgumentError,
            "unknown options #{inspect(unknown)} passed to Pyex.Ctx.new/1. " <>
              "Valid options: #{inspect(@valid_keys)}"
    end

    fs = Keyword.get(opts, :filesystem)
    mod = Keyword.get(opts, :fs_module)
    environ = Keyword.get(opts, :environ, %{})
    modules = Keyword.get(opts, :modules, %{}) |> normalize_modules()

    timeout_ns =
      case Keyword.get(opts, :timeout_ms) do
        nil -> nil
        ms when is_integer(ms) -> ms * 1_000_000
      end

    profile =
      if Keyword.get(opts, :profile, false),
        do: %{line_counts: %{}, call_counts: %{}, call_us: %{}},
        else: nil

    network = normalize_network(Keyword.get(opts, :network))
    capabilities = normalize_capabilities(opts)

    %__MODULE__{
      filesystem: fs,
      fs_module: mod,
      environ: environ,
      modules: modules,
      timeout_ns: timeout_ns,
      compute_ns: 0,
      compute_started_at: System.monotonic_time(:nanosecond),
      profile: profile,
      network: network,
      capabilities: capabilities
    }
  end

  @spec normalize_modules(%{optional(String.t()) => map() | module()}) ::
          %{optional(String.t()) => Pyex.Stdlib.Module.module_value()}
  defp normalize_modules(modules) when is_map(modules) do
    Map.new(modules, fn {name, value} ->
      {name, resolve_module_value(value)}
    end)
  end

  @spec resolve_module_value(map() | module()) :: Pyex.Stdlib.Module.module_value()
  defp resolve_module_value(mod) when is_atom(mod) do
    mod.module_value()
  end

  defp resolve_module_value(map) when is_map(map) do
    map
  end

  @spec normalize_capabilities(keyword()) :: MapSet.t(capability())
  defp normalize_capabilities(opts) do
    explicit = Keyword.get(opts, :capabilities, [])

    shorthand =
      for key <- [:boto3, :sql],
          Keyword.get(opts, key, false) == true,
          do: key

    MapSet.new(explicit ++ shorthand)
  end

  @spec normalize_network(keyword() | map() | nil) :: network_config() | nil
  defp normalize_network(nil), do: nil

  defp normalize_network(opts) when is_list(opts) do
    normalize_network(Map.new(opts))
  end

  defp normalize_network(opts) when is_map(opts) do
    %{
      allowed_hosts:
        Map.get(opts, :allowed_hosts, [])
        |> Enum.map(&(&1 |> to_string() |> String.downcase())),
      allowed_url_prefixes: Map.get(opts, :allowed_url_prefixes, []) |> Enum.map(&to_string/1),
      allowed_methods:
        Map.get(opts, :allowed_methods, ["GET", "HEAD"])
        |> Enum.map(&(&1 |> to_string() |> String.upcase())),
      dangerously_allow_full_internet_access:
        Map.get(opts, :dangerously_allow_full_internet_access, false) == true
    }
  end

  @doc """
  Checks whether a network request is allowed by the current policy.

  Returns `:ok` if the request is permitted, or `{:denied, reason}` with
  a descriptive error message when the request violates the policy.
  """
  @spec check_network_access(t(), String.t(), String.t()) :: :ok | {:denied, String.t()}
  def check_network_access(%__MODULE__{network: nil}, _method, _url) do
    {:denied,
     "NetworkError: network access is disabled. " <>
       "Configure the :network option to allow HTTP requests"}
  end

  def check_network_access(
        %__MODULE__{network: %{dangerously_allow_full_internet_access: true}},
        _method,
        _url
      ) do
    :ok
  end

  def check_network_access(%__MODULE__{network: config}, method, url) do
    method_upper = String.upcase(method)

    with :ok <- check_method(config.allowed_methods, method_upper),
         :ok <- check_url_allowed(config.allowed_hosts, config.allowed_url_prefixes, url) do
      :ok
    end
  end

  @spec check_method([String.t()], String.t()) :: :ok | {:denied, String.t()}
  defp check_method(allowed, method) do
    if method in allowed do
      :ok
    else
      {:denied,
       "NetworkError: HTTP method #{method} is not allowed. " <>
         "Allowed methods: #{Enum.join(allowed, ", ")}"}
    end
  end

  @spec check_url_allowed([String.t()], [String.t()], String.t()) ::
          :ok | {:denied, String.t()}
  defp check_url_allowed([], [], _url) do
    {:denied,
     "NetworkError: no allowed hosts or URL prefixes configured. " <>
       "Add hosts to :allowed_hosts or URL prefixes to :allowed_url_prefixes"}
  end

  defp check_url_allowed(hosts, prefixes, url) do
    host_match = hosts != [] and url_matches_host?(hosts, url)
    prefix_match = prefixes != [] and Enum.any?(prefixes, &String.starts_with?(url, &1))

    if host_match or prefix_match do
      :ok
    else
      parts =
        []
        |> then(fn acc ->
          if hosts != [], do: ["allowed hosts: #{Enum.join(hosts, ", ")}" | acc], else: acc
        end)
        |> then(fn acc ->
          if prefixes != [],
            do: ["allowed prefixes: #{Enum.join(prefixes, ", ")}" | acc],
            else: acc
        end)
        |> Enum.reverse()
        |> Enum.join("; ")

      {:denied, "NetworkError: URL is not allowed. #{String.capitalize(parts)}"}
    end
  end

  @spec url_matches_host?([String.t()], String.t()) :: boolean()
  defp url_matches_host?(allowed_hosts, url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        normalized = String.downcase(host)
        Enum.any?(allowed_hosts, &(&1 == normalized))

      _ ->
        false
    end
  end

  @doc """
  Checks whether a capability is enabled.

  Returns `:ok` if the capability is in the context's `capabilities`
  set, or `{:denied, reason}` with a `PermissionError` message.
  """
  @spec check_capability(t(), capability()) :: :ok | {:denied, String.t()}
  def check_capability(%__MODULE__{capabilities: caps}, capability) do
    if MapSet.member?(caps, capability) do
      :ok
    else
      {:denied,
       "PermissionError: #{capability} is disabled. " <>
         "Configure the :#{capability} option to enable access"}
    end
  end

  @doc """
  Wraps an I/O callback with a capability check.

  Returns an `{:io_call, fun}` tuple where `fun` first verifies
  the capability is enabled before executing the callback. If
  the capability is denied, returns an exception tuple without
  calling the callback.
  """
  @spec guarded_io_call(capability(), (Pyex.Env.t(), t() -> {term(), Pyex.Env.t(), t()})) ::
          {:io_call, (Pyex.Env.t(), t() -> {term(), Pyex.Env.t(), t()})}
  def guarded_io_call(capability, fun) do
    {:io_call,
     fn env, ctx ->
       case check_capability(ctx, capability) do
         {:denied, reason} -> {{:exception, reason}, env, ctx}
         :ok -> fun.(env, ctx)
       end
     end}
  end

  @doc """
  Checks whether accumulated compute time has exceeded the budget.

  Returns `:ok` if within budget (or no timeout set),
  or `{:exceeded, elapsed_ms}` if the budget is exhausted.
  I/O time is excluded from the computation.
  """
  @spec check_deadline(t()) :: :ok | {:exceeded, non_neg_integer()}
  def check_deadline(%__MODULE__{mode: :noop}), do: :ok
  def check_deadline(%__MODULE__{timeout_ns: nil}), do: :ok

  def check_deadline(%__MODULE__{
        timeout_ns: timeout_ns,
        compute_ns: acc,
        compute_started_at: started
      }) do
    elapsed = acc + (System.monotonic_time(:nanosecond) - (started || 0))

    if elapsed >= timeout_ns do
      {:exceeded, div(elapsed - timeout_ns, 1_000_000)}
    else
      :ok
    end
  end

  @doc """
  Pauses the compute clock before an I/O operation.

  Snapshots the elapsed compute time into `compute_ns` and
  clears `compute_started_at` so time spent in I/O is not counted.
  """
  @spec pause_compute(t()) :: t()
  def pause_compute(%__MODULE__{mode: :noop} = ctx), do: ctx
  def pause_compute(%__MODULE__{compute_started_at: nil} = ctx), do: ctx

  def pause_compute(%__MODULE__{compute_ns: acc, compute_started_at: started} = ctx) do
    elapsed = System.monotonic_time(:nanosecond) - started
    %{ctx | compute_ns: acc + elapsed, compute_started_at: nil}
  end

  @doc """
  Resumes the compute clock after an I/O operation completes.
  """
  @spec resume_compute(t()) :: t()
  def resume_compute(%__MODULE__{mode: :noop} = ctx), do: ctx

  def resume_compute(%__MODULE__{compute_started_at: nil} = ctx) do
    %{ctx | compute_started_at: System.monotonic_time(:nanosecond)}
  end

  def resume_compute(ctx), do: ctx

  @doc """
  Returns the total accumulated compute time in microseconds.
  """
  @spec compute_time_us(t()) :: non_neg_integer()
  def compute_time_us(%__MODULE__{compute_ns: acc, compute_started_at: nil}) do
    div(acc, 1_000)
  end

  def compute_time_us(%__MODULE__{compute_ns: acc, compute_started_at: started}) do
    elapsed = System.monotonic_time(:nanosecond) - started
    div(acc + elapsed, 1_000)
  end

  @doc """
  Creates a replay context from a previously captured log.

  The interpreter will consume events from the log. When the
  cursor reaches the end, it switches to live mode and continues
  recording.
  """
  @spec from_log([event()]) :: t()
  def from_log(log) when is_list(log) do
    %__MODULE__{
      mode: :replay,
      log: Enum.reverse(log),
      remaining: log,
      step: 0
    }
  end

  @doc """
  Records an event in live mode. Returns the updated context.

  In replay mode this is a no-op (the event is already in the log).
  """
  @spec record(t(), event_type(), term()) :: t()
  def record(%__MODULE__{mode: :noop} = ctx, _type, _data), do: ctx

  def record(%__MODULE__{mode: :live} = ctx, type, data) do
    event = {type, ctx.step, data}
    %{ctx | log: [event | ctx.log], step: ctx.step + 1}
  end

  def record(%__MODULE__{mode: :replay} = ctx, _type, _data), do: ctx

  @doc """
  Consumes the next event from the log in replay mode.

  Returns `{:ok, event, ctx}` if there is a matching event at
  the cursor, or `:live` if the log is exhausted (the context
  switches to live mode automatically).

  In live mode, always returns `:live`.
  """
  @spec consume(t(), event_type()) :: {:ok, event(), t()} | :live
  def consume(%__MODULE__{mode: :live}, _type), do: :live

  def consume(%__MODULE__{mode: :replay, remaining: []}, _type), do: :live

  def consume(%__MODULE__{mode: :replay, remaining: [event | rest]} = ctx, type) do
    case event do
      {^type, _step, _data} ->
        ctx = %{ctx | remaining: rest, step: ctx.step + 1}
        {:ok, event, ctx}

      _ ->
        :live
    end
  end

  @doc """
  Switches a replay context to live mode, keeping the log
  and step counter intact so new events append correctly.
  """
  @spec go_live(t()) :: t()
  def go_live(%__MODULE__{} = ctx) do
    %{ctx | mode: :live}
  end

  @doc """
  Returns the full event log.
  """
  @spec events(t()) :: [event()]
  def events(%__MODULE__{log: log}), do: Enum.reverse(log)

  @doc """
  Returns all captured print output as a single string.

  Extracts `:output` events from the log and joins them
  with newlines, matching how Python's `print()` separates
  lines.
  """
  @spec output(t()) :: String.t()
  def output(%__MODULE__{} = ctx) do
    ctx
    |> events()
    |> Enum.flat_map(fn
      {:output, _step, line} -> [line]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  @doc """
  Prepares a context for resume by setting it to replay mode
  with the cursor at the beginning.
  """
  @spec for_resume(t()) :: t()
  def for_resume(%__MODULE__{} = ctx) do
    ordered = events(ctx)

    %__MODULE__{
      mode: :replay,
      log: ctx.log,
      remaining: ordered,
      step: 0,
      filesystem: ctx.filesystem,
      fs_module: ctx.fs_module,
      handles: %{},
      next_handle: 0,
      environ: ctx.environ,
      modules: ctx.modules,
      imported_modules: %{},
      timeout_ns: ctx.timeout_ns,
      compute_ns: 0,
      compute_started_at: System.monotonic_time(:nanosecond),
      network: ctx.network,
      capabilities: ctx.capabilities
    }
  end

  @doc """
  Returns the event log truncated to `n` steps, for branching.

  Creates a new replay context from the first `n` events.
  """
  @spec branch_at(t(), non_neg_integer()) :: t()
  def branch_at(%__MODULE__{} = ctx, n) do
    truncated = Enum.take(events(ctx), n)
    from_log(truncated)
  end

  @doc """
  Opens a file handle, returning `{handle_id, ctx}`.
  """
  @spec open_handle(t(), String.t(), :read | :write | :append) ::
          {:ok, non_neg_integer(), t()} | {:error, String.t()}
  def open_handle(%__MODULE__{fs_module: nil}, _path, _mode) do
    {:error, "IOError: no filesystem configured"}
  end

  def open_handle(%__MODULE__{fs_module: mod, filesystem: fs} = ctx, path, mode) do
    case mode do
      :read ->
        case mod.read(fs, path) do
          {:ok, content} ->
            id = ctx.next_handle
            handle = %{path: path, mode: :read, buffer: content}
            ctx = %{ctx | handles: Map.put(ctx.handles, id, handle), next_handle: id + 1}
            ctx = record(ctx, :file_op, {:open, path, mode, id})
            {:ok, id, ctx}

          {:error, _} = err ->
            err
        end

      write_mode when write_mode in [:write, :append] ->
        id = ctx.next_handle
        handle = %{path: path, mode: write_mode, buffer: ""}
        ctx = %{ctx | handles: Map.put(ctx.handles, id, handle), next_handle: id + 1}
        ctx = record(ctx, :file_op, {:open, path, write_mode, id})
        {:ok, id, ctx}
    end
  end

  @doc """
  Reads content from an open file handle.
  """
  @spec read_handle(t(), non_neg_integer()) :: {:ok, String.t(), t()} | {:error, String.t()}
  def read_handle(%__MODULE__{handles: handles} = ctx, id) do
    case Map.fetch(handles, id) do
      {:ok, %{mode: :read, buffer: content}} ->
        ctx = record(ctx, :file_op, {:read, id, byte_size(content)})
        {:ok, content, ctx}

      {:ok, _} ->
        {:error, "IOError: not readable"}

      :error ->
        {:error, "ValueError: I/O operation on closed file"}
    end
  end

  @doc """
  Writes content to an open file handle's buffer.
  """
  @spec write_handle(t(), non_neg_integer(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def write_handle(%__MODULE__{handles: handles} = ctx, id, content) do
    case Map.fetch(handles, id) do
      {:ok, %{mode: mode} = handle} when mode in [:write, :append] ->
        handle = %{handle | buffer: handle.buffer <> content}
        ctx = %{ctx | handles: Map.put(handles, id, handle)}
        ctx = record(ctx, :file_op, {:write, id, byte_size(content)})
        {:ok, ctx}

      {:ok, _} ->
        {:error, "IOError: not writable"}

      :error ->
        {:error, "ValueError: I/O operation on closed file"}
    end
  end

  @doc """
  Closes a file handle, flushing writes to the filesystem.
  """
  @spec close_handle(t(), non_neg_integer()) :: {:ok, t()} | {:error, String.t()}
  def close_handle(%__MODULE__{handles: handles, fs_module: mod, filesystem: fs} = ctx, id) do
    case Map.fetch(handles, id) do
      {:ok, %{mode: mode, path: path, buffer: buffer}} when mode in [:write, :append] ->
        case mod.write(fs, path, buffer, mode) do
          {:ok, new_fs} ->
            ctx = %{ctx | handles: Map.delete(handles, id), filesystem: new_fs}
            ctx = record(ctx, :file_op, {:close, id})
            {:ok, ctx}

          {:error, _} = err ->
            err
        end

      {:ok, _} ->
        ctx = %{ctx | handles: Map.delete(handles, id)}
        ctx = record(ctx, :file_op, {:close, id})
        {:ok, ctx}

      :error ->
        {:error, "ValueError: I/O operation on closed file"}
    end
  end

  @doc """
  Creates a new iterator from a list of items, returning the
  iterator token and updated context.
  """
  @spec new_iterator(t(), [term()]) :: {{:iterator, non_neg_integer()}, t()}
  def new_iterator(%__MODULE__{iterators: iters, next_iterator_id: id} = ctx, items) do
    ctx = %{ctx | iterators: Map.put(iters, id, {:list, items}), next_iterator_id: id + 1}
    {{:iterator, id}, ctx}
  end

  @doc """
  Creates a new instance-based iterator, returning the
  iterator token and updated context.
  """
  @spec new_instance_iterator(t(), term()) :: {{:iterator, non_neg_integer()}, t()}
  def new_instance_iterator(%__MODULE__{iterators: iters, next_iterator_id: id} = ctx, instance) do
    ctx = %{ctx | iterators: Map.put(iters, id, {:instance, instance}), next_iterator_id: id + 1}
    {{:iterator, id}, ctx}
  end

  @doc """
  Advances a plain list iterator, returning the next item
  or `:exhausted` if the iterator is empty.
  """
  @spec iter_next(t(), non_neg_integer()) :: {:ok, term(), t()} | :exhausted | {:instance, term()}
  def iter_next(%__MODULE__{iterators: iters} = ctx, id) do
    case Map.get(iters, id) do
      {:list, [item | rest]} ->
        ctx = %{ctx | iterators: Map.put(iters, id, {:list, rest})}
        {:ok, item, ctx}

      {:list, []} ->
        :exhausted

      {:instance, inst} ->
        {:instance, inst}

      nil ->
        :exhausted
    end
  end

  @doc """
  Returns the remaining items in a list iterator, or `[]`
  if the iterator is exhausted or unknown.
  """
  @spec iter_items(t(), non_neg_integer()) :: [term()]
  def iter_items(%__MODULE__{iterators: iters}, id) do
    case Map.get(iters, id) do
      {:list, items} -> items
      _ -> []
    end
  end

  @doc """
  Updates the instance stored in an instance-based iterator.
  """
  @spec update_instance_iterator(t(), non_neg_integer(), term()) :: t()
  def update_instance_iterator(%__MODULE__{iterators: iters} = ctx, id, new_inst) do
    %{ctx | iterators: Map.put(iters, id, {:instance, new_inst})}
  end

  @doc """
  Removes an iterator from the context.
  """
  @spec delete_iterator(t(), non_neg_integer()) :: t()
  def delete_iterator(%__MODULE__{iterators: iters} = ctx, id) do
    %{ctx | iterators: Map.delete(iters, id)}
  end
end
