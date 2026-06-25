defmodule Pyex.Ctx do
  @moduledoc """
  Execution context for the Pyex interpreter.

  Carries all external configuration -- filesystem, environment
  variables, custom modules, compute budget, network policy, and
  I/O capabilities. Threaded through every `eval` call alongside
  the environment.

  Most users don't need to construct a `Ctx` directly. Pass
  keyword options to `Pyex.run/2` instead:

      Pyex.run(source,
        env: %{"KEY" => "val"},
        timeout: 5_000,
        modules: %{"mylib" => %{...}})

  Use `Ctx.new/1` when you need to share a context across
  multiple calls (e.g. Lambda boot + handle):

      ctx = Ctx.new(filesystem: Memory.new())
      {:ok, app} = Lambda.boot(source, ctx: ctx)
  """

  @type event_type :: :output | :file_op | :loop

  @type file_handle :: %{
          :path => String.t(),
          :mode => :read | :write | :append,
          :buffer => String.t(),
          optional(:pos) => non_neg_integer()
        }

  @type profile_data :: %{
          line_counts: %{optional(pos_integer()) => pos_integer()},
          call_counts: %{optional(String.t()) => pos_integer()},
          call: %{optional(String.t()) => float()}
        }

  @type network_rule :: %{
          optional(:allowed_url_prefix) => String.t(),
          optional(:dangerously_allow_full_internet_access) => true,
          optional(:methods) => [String.t()] | :all,
          optional(:headers) => %{optional(String.t()) => String.t()}
        }

  @type network_config :: [network_rule()] | nil

  @type capability :: :boto3 | :sql | atom()

  @type generator_mode :: :accumulate | :defer | :defer_inner | :lazy_iter | nil

  @type t :: %__MODULE__{
          filesystem: term(),
          handles: %{optional(non_neg_integer()) => file_handle()},
          next_handle: non_neg_integer(),
          env: %{optional(String.t()) => String.t()},
          modules: %{optional(String.t()) => Pyex.Stdlib.Module.module_value()},
          imported_modules: %{optional(String.t()) => Pyex.Stdlib.Module.module_value()},
          timeout: non_neg_integer() | nil,
          compute: float(),
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
          max_call_depth: non_neg_integer(),
          output_buffer: [String.t()],
          event_count: non_neg_integer(),
          file_ops: non_neg_integer(),
          duration_ms: float() | nil,
          file: String.t() | nil,
          heap: %{optional(non_neg_integer()) => term()},
          next_heap_id: non_neg_integer(),
          list_index_cache: %{optional(non_neg_integer()) => tuple()},
          limits: Pyex.Limits.t(),
          steps: non_neg_integer(),
          memory_bytes: non_neg_integer(),
          output_bytes: non_neg_integer(),
          asyncio_running: boolean()
        }

  defstruct filesystem: nil,
            handles: %{},
            next_handle: 0,
            env: %{},
            modules: %{},
            imported_modules: %{},
            timeout: nil,
            compute: 0.0,
            output_buffer: [],
            event_count: 0,
            file_ops: 0,
            compute_started_at: nil,
            profile: nil,
            generator_mode: :lazy_iter,
            generator_acc: nil,
            iterators: %{},
            next_iterator_id: 0,
            network: nil,
            capabilities: MapSet.new(),
            exception_instance: nil,
            current_line: nil,
            call_depth: 0,
            max_call_depth: 500,
            duration_ms: nil,
            file: nil,
            heap: %{},
            next_heap_id: 0,
            list_index_cache: %{},
            limits: %Pyex.Limits{},
            steps: 0,
            memory_bytes: 0,
            output_bytes: 0,
            asyncio_running: false

  @doc """
  Creates a fresh live context that captures output and execution counters.

  Options:
  - `:filesystem` -- a filesystem backend struct (e.g. `Pyex.Filesystem.Memory.new()`).
    The implementing module is derived automatically from the struct.
  - `:env` -- a map of environment variables accessible via `os.environ`
  - `:modules` -- custom Python modules available via `import`. A map from
    module name strings to either a `%{String.t() => pyvalue()}` map or a
    module implementing `Pyex.Stdlib.Module`.
  - `:timeout` -- maximum *compute* time in milliseconds (nil = no limit).
    I/O time (HTTP requests, SQL queries) does not count against the budget.
  - `:profile` -- when `true`, collects per-line execution counts and
    per-function call counts with timing. Results are stored in the
    returned context's `profile` field. Default `false`.
  - `:network` -- network access policy for the `requests` module.

    A list of rule maps. Each rule may contain:
    - `:allowed_url_prefix` -- absolute URL prefix that is permitted.
      Matched component-wise: the request's scheme, host, and port must
      match exactly and its path must fall at or below the prefix path
      on a segment boundary, so `"https://api.example.com/"` permits
      `"https://api.example.com/v1"` but never `"...example.com.evil.com/"`
      or a different port. A bare trailing `":"` (e.g. `"http://localhost:"`)
      matches the host on any port.
    - `:dangerously_allow_full_internet_access` -- `true` to match any URL
    - `:methods` -- list of HTTP methods allowed (default `["GET", "HEAD"]`)
    - `:headers` -- map of headers to inject into matching requests.
      Injected headers override any headers set by the Python code,
      and are not visible to the sandboxed code.

    Each rule must have either `:allowed_url_prefix` or
    `:dangerously_allow_full_internet_access`. A request is allowed if
    it matches any rule (URL prefix + method). When `nil` (the default),
    all network access is denied.

    ## Examples

        # Prefix rules with credential injection
        network: [
          %{allowed_url_prefix: "https://api.openai.com/v1/",
            methods: ["POST"],
            headers: %{"authorization" => "Bearer sk-..."}},
          %{allowed_url_prefix: "https://httpbin.org/"}
        ]

        # GET everything, POST to a specific API with injected auth
        network: [
          %{dangerously_allow_full_internet_access: true, methods: ["GET"]},
          %{allowed_url_prefix: "https://api.openai.com/v1/",
            methods: ["POST"],
            headers: %{"authorization" => "Bearer sk-..."}}
        ]
  - `:capabilities` -- a list of atoms naming enabled I/O capabilities.
    Known capabilities: `:boto3` (S3 operations), `:sql` (database
    queries). All capabilities are denied by default.
  - `:boto3` -- shorthand for adding `:boto3` to capabilities.
  - `:sql` -- shorthand for adding `:sql` to capabilities.
  """
  @valid_keys [
    :filesystem,
    :env,
    :modules,
    :timeout,
    :limits,
    :profile,
    :network,
    :capabilities,
    :boto3,
    :sql,
    :file
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
    env = Keyword.get(opts, :env, %{})
    modules = Keyword.get(opts, :modules, %{}) |> normalize_modules()

    limits = normalize_limits(opts)

    timeout =
      case limits.timeout do
        :infinity -> Keyword.get(opts, :timeout)
        ms -> ms
      end

    profile =
      if Keyword.get(opts, :profile, false),
        do: %{line_counts: %{}, call_counts: %{}, call: %{}},
        else: nil

    network = normalize_network(Keyword.get(opts, :network))
    capabilities = normalize_capabilities(opts)
    file = Keyword.get(opts, :file)

    %__MODULE__{
      filesystem: fs,
      env: env,
      modules: modules,
      timeout: timeout,
      compute: 0.0,
      compute_started_at: System.monotonic_time(),
      profile: profile,
      network: network,
      capabilities: capabilities,
      file: file,
      limits: limits
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

  @spec normalize_limits(keyword()) :: Pyex.Limits.t()
  defp normalize_limits(opts) do
    case Keyword.get(opts, :limits) do
      nil -> %Pyex.Limits{}
      :none -> Pyex.Limits.unbounded()
      %Pyex.Limits{} = l -> l
      kw when is_list(kw) -> Pyex.Limits.new(kw)
    end
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

  @spec normalize_network(term()) :: network_config()
  defp normalize_network(nil), do: nil
  defp normalize_network([]), do: []

  defp normalize_network(rules) when is_list(rules) do
    if Keyword.keyword?(rules) do
      raise ArgumentError,
            "network must be a list of rule maps, not a keyword list. " <>
              "Use network: [%{allowed_url_prefix: \"https://api.example.com/\"}]"
    end

    Enum.map(rules, &normalize_rule/1)
  end

  defp normalize_network(%{}), do: raise_invalid_network_config()

  defp normalize_network(_), do: raise_invalid_network_config()

  @spec raise_invalid_network_config() :: no_return()
  defp raise_invalid_network_config do
    raise ArgumentError,
          "network must be a list of rule maps. " <>
            "Use network: [%{allowed_url_prefix: \"https://api.example.com/\"}]"
  end

  @spec normalize_rule(term()) :: network_rule()
  defp normalize_rule(%{} = rule) do
    has_prefix = Map.has_key?(rule, :allowed_url_prefix)
    has_dangerous = Map.get(rule, :dangerously_allow_full_internet_access, false) == true

    unless has_prefix or has_dangerous do
      raise ArgumentError,
            "network rule must have :allowed_url_prefix or :dangerously_allow_full_internet_access"
    end

    methods =
      case Map.get(rule, :methods, ["GET", "HEAD"]) do
        :all ->
          :all

        list when is_list(list) ->
          Enum.map(list, &(&1 |> to_string() |> String.upcase()))

        _ ->
          raise ArgumentError, "network rule :methods must be a list of strings or :all"
      end

    headers =
      case Map.get(rule, :headers, %{}) do
        %{} = headers ->
          Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

        _ ->
          raise ArgumentError, "network rule :headers must be a map"
      end

    base = %{methods: methods, headers: headers}

    if has_prefix do
      Map.put(base, :allowed_url_prefix, normalize_allowed_url_prefix(rule.allowed_url_prefix))
    else
      Map.put(base, :dangerously_allow_full_internet_access, true)
    end
  end

  defp normalize_rule(_) do
    raise ArgumentError, "each network rule must be a map"
  end

  @spec normalize_allowed_url_prefix(term()) :: String.t()
  defp normalize_allowed_url_prefix(prefix) when is_binary(prefix) and prefix != "" do
    uri = URI.parse(prefix)

    if is_nil(uri.scheme) or not host_present?(uri.host) do
      raise ArgumentError,
            "network rule :allowed_url_prefix must be an absolute URL with a scheme and host " <>
              "(e.g. \"https://api.example.com/\"), got: #{inspect(prefix)}"
    end

    prefix
  end

  defp normalize_allowed_url_prefix(_) do
    raise ArgumentError, "network rule :allowed_url_prefix must be a non-empty string"
  end

  @doc """
  Checks whether a network request is allowed by the current policy.

  Returns `{:ok, inject_headers}` if the request is permitted (where
  `inject_headers` is a list of `{name, value}` tuples to merge into
  the request), or `{:denied, reason}` with a descriptive error message.
  """
  @spec check_network_access(t(), String.t(), String.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:denied, String.t()}
  def check_network_access(%__MODULE__{network: nil}, _method, _url) do
    {:denied,
     "NetworkError: network access is disabled. " <>
       "Configure the :network option to allow HTTP requests"}
  end

  def check_network_access(%__MODULE__{network: []}, _method, _url) do
    {:denied,
     "NetworkError: no network rules configured. " <>
       "Add rules to the :network option to allow HTTP requests"}
  end

  def check_network_access(%__MODULE__{network: rules}, method, url) do
    method_upper = String.upcase(method)

    case find_matching_rules(rules, method_upper, url) do
      {:ok, headers} -> {:ok, headers}
      :no_match -> {:denied, build_denial_message(rules, method_upper, url)}
    end
  end

  @spec find_matching_rules([network_rule()], String.t(), String.t()) ::
          {:ok, [{String.t(), String.t()}]} | :no_match
  defp find_matching_rules(rules, method, url) do
    rules
    |> Enum.filter(&(rule_matches_url?(&1, url) and rule_allows_method?(&1, method)))
    |> merge_matching_rule_headers()
  end

  @spec merge_matching_rule_headers([network_rule()]) ::
          {:ok, [{String.t(), String.t()}]} | :no_match
  defp merge_matching_rule_headers([]), do: :no_match

  defp merge_matching_rule_headers(rules) do
    headers =
      rules
      |> Enum.with_index()
      |> Enum.sort_by(fn {rule, index} -> {rule_specificity(rule), index} end)
      |> Enum.reduce(%{}, fn {rule, _index}, acc ->
        Map.merge(acc, Map.get(rule, :headers, %{}))
      end)

    {:ok, Enum.to_list(headers)}
  end

  @spec rule_allows_method?(network_rule(), String.t()) :: boolean()
  defp rule_allows_method?(%{methods: :all}, _method), do: true
  defp rule_allows_method?(%{methods: methods}, method), do: method in methods

  @spec rule_matches_url?(network_rule(), String.t()) :: boolean()
  defp rule_matches_url?(%{dangerously_allow_full_internet_access: true}, _url), do: true

  defp rule_matches_url?(%{allowed_url_prefix: prefix}, url),
    do: url_within_prefix?(URI.parse(url), URI.parse(prefix), prefix)

  defp rule_matches_url?(_, _url), do: false

  # Matches component-wise rather than as a raw string prefix. Scheme, host,
  # and port must be equal, and the URL path must lie at or below the prefix
  # path on a segment boundary. This closes two `String.starts_with?` bypasses:
  # the subdomain bypass ("https://api.example.com" vs
  # "https://api.example.com.attacker.com/") and the path-segment bypass
  # ("https://host/v1" vs "https://host/v1abc/anything"). Comparing hosts
  # (never userinfo) also rejects the "https://api.example.com@evil.com/" trick.
  # A prefix whose authority ends in a bare ":" (e.g. "http://localhost:")
  # matches the host on any port.
  @spec url_within_prefix?(URI.t(), URI.t(), String.t()) :: boolean()
  defp url_within_prefix?(url, prefix, raw_prefix) do
    url_path = request_path(url.path)

    host_present?(url.host) and
      downcase(url.scheme) == downcase(prefix.scheme) and
      downcase(url.host) == downcase(prefix.host) and
      port_match?(url.port, prefix.port, raw_prefix) and
      not dot_dot_segment?(url_path) and
      path_within_prefix?(url_path, request_path(prefix.path))
  end

  @spec host_present?(term()) :: boolean()
  defp host_present?(host), do: is_binary(host) and host != ""

  @spec downcase(String.t() | nil) :: String.t() | nil
  defp downcase(nil), do: nil
  defp downcase(string), do: String.downcase(string)

  # A bare trailing ":" in the prefix authority (no port digits) is a wildcard
  # that matches any port; otherwise the effective ports (defaults filled in by
  # URI.parse) must be equal. The wildcard is read off the raw prefix string so
  # we never touch URI's opaque `authority` field.
  @spec port_match?(non_neg_integer() | nil, non_neg_integer() | nil, String.t()) :: boolean()
  defp port_match?(url_port, prefix_port, raw_prefix),
    do: any_port_prefix?(raw_prefix) or url_port == prefix_port

  @spec any_port_prefix?(String.t()) :: boolean()
  defp any_port_prefix?(raw_prefix) do
    case String.split(raw_prefix, "://", parts: 2) do
      [_scheme, rest] ->
        rest |> String.split(["/", "?", "#"], parts: 2) |> hd() |> String.ends_with?(":")

      _ ->
        false
    end
  end

  @spec request_path(String.t() | nil) :: String.t()
  defp request_path(nil), do: "/"
  defp request_path(""), do: "/"
  defp request_path(path), do: path

  @spec path_within_prefix?(String.t(), String.t()) :: boolean()
  defp path_within_prefix?(url_path, prefix_path) do
    cond do
      url_path == prefix_path -> true
      String.ends_with?(prefix_path, "/") -> String.starts_with?(url_path, prefix_path)
      true -> String.starts_with?(url_path, prefix_path <> "/")
    end
  end

  # A ".." path segment lets a request climb above the prefix subtree once a
  # client or server applies RFC-3986 dot-segment removal (e.g. "/v1/../../admin"
  # resolves to "/admin"), so a path containing one is treated as outside the
  # prefix. URI.parse does not collapse dot-segments, and the check is done on
  # the percent-decoded path so "%2e%2e" and "%2f"-smuggled separators are
  # caught too; matching whole segments avoids false positives like "version..1".
  @spec dot_dot_segment?(String.t()) :: boolean()
  defp dot_dot_segment?(path) do
    path
    |> URI.decode()
    |> String.split("/")
    |> Enum.any?(&(&1 == ".."))
  end

  @spec rule_specificity(network_rule()) :: non_neg_integer()
  defp rule_specificity(%{allowed_url_prefix: prefix}), do: byte_size(prefix)
  defp rule_specificity(%{dangerously_allow_full_internet_access: true}), do: 0

  @spec build_denial_message([network_rule()], String.t(), String.t()) :: String.t()
  defp build_denial_message(rules, method, url) do
    url_matched_rules = Enum.filter(rules, &rule_matches_url?(&1, url))

    if url_matched_rules != [] do
      has_all = Enum.any?(url_matched_rules, &(&1.methods == :all))

      allowed =
        if has_all,
          do: ["*"],
          else: url_matched_rules |> Enum.flat_map(& &1.methods) |> Enum.uniq()

      "NetworkError: HTTP method #{method} is not allowed. " <>
        "Allowed methods: #{Enum.join(allowed, ", ")}. " <>
        "To permit #{method}, add it to the matching rule's :methods list " <>
        "(e.g. methods: [\"GET\", \"#{method}\"])"
    else
      prefixes =
        rules
        |> Enum.filter(&Map.has_key?(&1, :allowed_url_prefix))
        |> Enum.map(& &1.allowed_url_prefix)

      if prefixes == [] do
        "NetworkError: URL is not allowed"
      else
        "NetworkError: URL is not allowed. " <>
          "Allowed prefixes: #{Enum.join(prefixes, ", ")}"
      end
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
  Checks all resource limits at a step boundary.

  Returns `{:ok, updated_ctx}` if within all limits, or
  `{:exceeded, kind, message}` if any limit is exceeded.

  Called at every loop iteration, function call entry,
  comprehension element, and generator yield.
  """
  @spec check_limits(t()) :: {:ok, t()} | {:exceeded, atom(), String.t()}
  def check_limits(%__MODULE__{limits: limits} = ctx) do
    cond do
      limits.max_steps != :infinity and ctx.steps >= limits.max_steps ->
        {:exceeded, :steps, "LimitError: step limit exceeded (#{limits.max_steps})"}

      limits.max_memory_bytes != :infinity and ctx.memory_bytes >= limits.max_memory_bytes ->
        {:exceeded, :memory,
         "LimitError: memory limit exceeded (#{limits.max_memory_bytes} bytes)"}

      limits.max_output_bytes != :infinity and ctx.output_bytes >= limits.max_output_bytes ->
        {:exceeded, :output,
         "LimitError: output limit exceeded (#{limits.max_output_bytes} bytes)"}

      true ->
        {:ok, %{ctx | steps: ctx.steps + 1}}
    end
  end

  @doc """
  Tracks an estimated memory allocation in bytes.
  """
  @spec track_memory(t(), non_neg_integer()) :: t()
  def track_memory(%__MODULE__{} = ctx, bytes) do
    %{ctx | memory_bytes: ctx.memory_bytes + bytes}
  end

  @doc """
  Estimates the memory cost of a Python value in bytes.
  """
  @spec estimate_memory(term()) :: non_neg_integer()
  def estimate_memory(value) do
    case value do
      v when is_binary(v) -> byte_size(v)
      {:py_list, _reversed, len} -> 64 + 8 * len
      {:py_dict, dict, _order} -> 128 + 48 * map_size(dict)
      {:set, s} -> 96 + 32 * MapSet.size(s)
      {:tuple, items} -> 64 + 8 * length(items)
      {:instance, _, attrs} -> 128 + 48 * map_size(attrs)
      list when is_list(list) -> 64 + 8 * length(list)
      _ -> 0
    end
  end

  @doc """
  Checks all resource limits and the compute deadline at a step boundary.

  Returns `{:ok, updated_ctx}` if everything is within budget, or
  `{:exceeded, message}` if any limit or the deadline is exceeded.

  This is the single function that should be called at step boundaries —
  it combines `check_limits/1` and `check_deadline/1`.
  """
  @spec check_step(t()) :: {:ok, t()} | {:exceeded, String.t()}
  # Fast path: the run has no enforceable budget — no compute timeout
  # and every resource cap is :infinity.  `check_step` is called on
  # every loop iteration / statement / call entry, and the slow path
  # below allocates a new ctx (incrementing `steps`) on every hit, so
  # short-circuiting here removes a per-step map update plus three
  # cond branches plus the `System.monotonic_time/0` syscall behind
  # `check_deadline/1`.  In the default no-limits run this is ~13%
  # of wall time on tight compute loops; see scratch/robot_graders_*.
  #
  # The cost is that `ctx.steps` stops advancing — that field is only
  # read by `check_limits/1` itself (and is not part of the public
  # `Pyex.Ctx` contract), so this is safe.
  def check_step(
        %__MODULE__{
          timeout: nil,
          limits: %Pyex.Limits{
            max_steps: :infinity,
            max_memory_bytes: :infinity,
            max_output_bytes: :infinity
          }
        } = ctx
      ) do
    {:ok, ctx}
  end

  def check_step(%__MODULE__{} = ctx) do
    case check_limits(ctx) do
      {:exceeded, _kind, message} ->
        {:exceeded, message}

      {:ok, ctx} ->
        case check_deadline(ctx) do
          {:exceeded, _} ->
            {:exceeded, "TimeoutError: execution exceeded time limit"}

          :ok ->
            {:ok, ctx}
        end
    end
  end

  @doc """
  Checks whether accumulated compute time has exceeded the budget.

  Returns `:ok` if within budget (or no timeout set),
  or `{:exceeded, elapsed_ms}` if the budget is exhausted.
  I/O time is excluded from the computation.
  """
  @spec check_deadline(t()) :: :ok | {:exceeded, float()}
  def check_deadline(%__MODULE__{timeout: nil}), do: :ok

  def check_deadline(%__MODULE__{
        timeout: timeout,
        compute: acc_us,
        compute_started_at: started
      }) do
    now = System.monotonic_time()
    started_native = started || now
    elapsed_us = acc_us + native_to_microseconds(now - started_native)
    elapsed_ms = elapsed_us / 1000

    if elapsed_ms >= timeout do
      {:exceeded, elapsed_ms - timeout}
    else
      :ok
    end
  end

  @doc """
  Pauses the compute clock before an I/O operation.

  Snapshots the elapsed compute time into `compute` (in microseconds)
  and clears `compute_started_at` so time spent in I/O is not counted.
  """
  @spec pause_compute(t()) :: t()
  def pause_compute(%__MODULE__{compute_started_at: nil} = ctx), do: ctx

  def pause_compute(%__MODULE__{compute: acc_us, compute_started_at: started} = ctx) do
    elapsed_us = acc_us + native_to_microseconds(System.monotonic_time() - started)
    %{ctx | compute: elapsed_us, compute_started_at: nil}
  end

  @doc """
  Resumes the compute clock after an I/O operation completes.
  """
  @spec resume_compute(t()) :: t()
  def resume_compute(%__MODULE__{compute_started_at: nil} = ctx) do
    %{ctx | compute_started_at: System.monotonic_time()}
  end

  def resume_compute(ctx), do: ctx

  @doc """
  Returns the total accumulated compute time in milliseconds.
  """
  @spec compute_time(t()) :: float()
  def compute_time(%__MODULE__{compute: acc_us, compute_started_at: nil}) do
    acc_us / 1000
  end

  def compute_time(%__MODULE__{compute: acc_us, compute_started_at: started}) do
    elapsed_us = acc_us + native_to_microseconds(System.monotonic_time() - started)
    elapsed_us / 1000
  end

  @doc """
  Returns the compute time remaining before the deadline, in milliseconds.

  `:infinity` when no compute timeout is configured. Never negative — a run
  that has already overrun its budget reports `0`. Callers that perform a
  single long-running compute step (e.g. a regex evaluation) can use this to
  bound that step by the run's remaining budget instead of an unrelated fixed
  ceiling.
  """
  @spec remaining_compute_ms(t()) :: non_neg_integer() | :infinity
  def remaining_compute_ms(%__MODULE__{timeout: nil}), do: :infinity

  def remaining_compute_ms(%__MODULE__{timeout: timeout} = ctx) do
    max(timeout - round(compute_time(ctx)), 0)
  end

  @spec native_to_microseconds(integer()) :: integer()
  defp native_to_microseconds(native) do
    System.convert_time_unit(native, :native, :microsecond)
  end

  @doc """
  Records output or file operation events. Returns the updated context.

  Note: Only :output and :file_op events are tracked for counting
  purposes. The actual event data is not stored to reduce memory allocation.
  """
  @spec record(t(), event_type(), term()) :: t()
  def record(ctx, :output, line) do
    output_size = if is_binary(line), do: byte_size(line), else: 0

    %{
      ctx
      | output_buffer: [line | ctx.output_buffer],
        event_count: ctx.event_count + 1,
        output_bytes: ctx.output_bytes + output_size
    }
  end

  def record(ctx, :file_op, _data) do
    %{ctx | event_count: ctx.event_count + 1, file_ops: ctx.file_ops + 1}
  end

  def record(ctx, :loop, _data) do
    %{ctx | event_count: ctx.event_count + 1}
  end

  @doc """
  Returns all captured print output as an iolist.

  Each buffer entry already includes its terminator (the `end`
  argument to `print()`, which defaults to `"\\n"`).  The buffer
  stores entries in reverse order (newest first); this function
  simply reverses back to chronological order.

  ## Example

      {:ok, _val, ctx} = Pyex.run("print('hello')")
      ["hello\\n"] = Pyex.output(ctx)

      {:ok, _val, ctx} = Pyex.run("print('a')\\nprint('b')")
      ["a\\n", "b\\n"] = Pyex.output(ctx)
  """
  @spec output(t()) :: iolist()
  def output(%__MODULE__{output_buffer: []}), do: []

  def output(%__MODULE__{output_buffer: buffer}) do
    Enum.reverse(buffer)
  end

  @doc """
  Allocates a mutable Python value on the heap and returns its ref.

  Returns `{{:ref, id}, updated_ctx}`.  The caller stores the ref
  in the environment; the actual value lives on the heap so that
  aliases (e.g. `b = a`) share the same heap slot.
  """
  @spec heap_alloc(t(), term()) :: {{:ref, non_neg_integer()}, t()}
  def heap_alloc(%__MODULE__{heap: heap, next_heap_id: id} = ctx, value) do
    mem = estimate_memory(value)

    ctx = %{
      ctx
      | heap: Map.put(heap, id, value),
        next_heap_id: id + 1,
        memory_bytes: ctx.memory_bytes + mem
    }

    {{:ref, id}, ctx}
  end

  @doc """
  Dereferences a value.  If it's a `{:ref, id}` tuple, looks up the
  current heap value.  Otherwise returns the value unchanged.

  This is the primary read operation — every site that pattern-matches
  on a Python value's shape must deref first.
  """
  @spec deref(t(), term()) :: term()
  def deref(%__MODULE__{heap: heap}, {:ref, id}), do: Map.fetch!(heap, id)
  def deref(_ctx, value), do: value

  @doc """
  Looks up `forward_idx` in a heap-stored `py_list`, using a lazy
  tuple cache.

  Cost model: the cache costs O(N) to build (reverse + List.to_tuple).
  A list indexed only once is *more* expensive to cache than to walk,
  so the cache uses **second-access promotion**:

  1. First int subscript on an id: walk the reverse-cons list (the
     pre-existing O(j) path) and record `:pending` in the cache.
  2. Second int subscript on the same id: build the tuple, replace
     `:pending` with it.
  3. Third+ subscripts: O(1) `:erlang.element/2`.

  Mutations clear the entry via `heap_put/3`, so the next subscript
  starts over from step 1.

  Returns `{value, updated_ctx}`.  The caller is responsible for
  having bounds-checked `forward_idx` already.
  """
  @spec list_index_lookup(t(), non_neg_integer(), non_neg_integer(), [term()], non_neg_integer()) ::
          {term(), t()}
  def list_index_lookup(
        %__MODULE__{list_index_cache: cache} = ctx,
        id,
        forward_idx,
        reversed,
        storage_idx
      ) do
    case Map.fetch(cache, id) do
      {:ok, tup} when is_tuple(tup) ->
        {:erlang.element(forward_idx + 1, tup), ctx}

      {:ok, :pending} ->
        tup = reversed |> Enum.reverse() |> List.to_tuple()
        ctx = %{ctx | list_index_cache: Map.put(cache, id, tup)}
        {:erlang.element(forward_idx + 1, tup), ctx}

      :error ->
        ctx = %{ctx | list_index_cache: Map.put(cache, id, :pending)}
        {Enum.at(reversed, storage_idx), ctx}
    end
  end

  @doc """
  Recursively dereferences all refs in a value tree.  Used for
  equality comparison and at the API boundary to convert the
  internal heap-ref representation back to plain values.

  Uses a visited set to handle circular references (e.g. linked
  list nodes pointing to each other).
  """
  @spec deep_deref(t(), term()) :: term()
  def deep_deref(ctx, value), do: deep_deref(ctx, value, MapSet.new())

  @dialyzer {:no_opaque, deep_deref: 3}
  @spec deep_deref(t(), term(), MapSet.t()) :: term()
  def deep_deref(%__MODULE__{} = ctx, {:ref, id} = ref, visited) do
    cond do
      MapSet.member?(visited, id) ->
        ref

      # StringIO must round-trip through heap refs so callers with an
      # aliased reference (e.g. a csv.writer holding it in a closure)
      # observe each other's writes.  Preserve the ref; consumers who
      # actually need the buffer string call `deref` themselves.
      match?({:stringio, _}, deref(ctx, ref)) ->
        ref

      true ->
        deep_deref(ctx, deref(ctx, ref), MapSet.put(visited, id))
    end
  end

  def deep_deref(%__MODULE__{} = ctx, {:py_list, reversed, len}, visited) do
    {:py_list, Enum.map(reversed, &deep_deref(ctx, &1, visited)), len}
  end

  def deep_deref(%__MODULE__{} = ctx, {:py_dict, _, _} = dict, visited) do
    pairs = Pyex.PyDict.items(dict)

    Enum.reduce(pairs, Pyex.PyDict.new(), fn {k, v}, acc ->
      Pyex.PyDict.put(acc, deep_deref(ctx, k, visited), deep_deref(ctx, v, visited))
    end)
  end

  def deep_deref(%__MODULE__{}, %_{} = struct, _visited), do: struct

  def deep_deref(%__MODULE__{} = ctx, map, visited) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, deep_deref(ctx, v, visited)} end)
  end

  def deep_deref(%__MODULE__{} = ctx, list, visited) when is_list(list) do
    Enum.map(list, &deep_deref(ctx, &1, visited))
  end

  def deep_deref(%__MODULE__{} = ctx, {:tuple, items}, visited) do
    {:tuple, Enum.map(items, &deep_deref(ctx, &1, visited))}
  end

  def deep_deref(%__MODULE__{} = ctx, {:set, s}, visited) do
    {:set, MapSet.new(s, &deep_deref(ctx, &1, visited))}
  end

  def deep_deref(%__MODULE__{} = ctx, {:instance, class, attrs}, visited) do
    {:instance, class, Map.new(attrs, fn {k, v} -> {k, deep_deref(ctx, v, visited)} end)}
  end

  def deep_deref(%__MODULE__{} = ctx, {:class, name, bases, attrs}, visited) do
    {:class, name, Enum.map(bases, &deep_deref(ctx, &1, visited)),
     Map.new(attrs, fn {k, v} -> {k, deep_deref(ctx, v, visited)} end)}
  end

  def deep_deref(%__MODULE__{} = ctx, {:generator, items}, visited) do
    {:generator, Enum.map(items, &deep_deref(ctx, &1, visited))}
  end

  def deep_deref(_ctx, value, _visited), do: value

  @doc """
  Updates the heap value for an existing ref.

  This is the primary write operation for mutable Python objects.
  All aliases of the same ref see the new value immediately.
  """
  @spec heap_put(t(), non_neg_integer(), term()) :: t()
  def heap_put(%__MODULE__{heap: heap, list_index_cache: cache} = ctx, id, value) do
    old_mem = estimate_memory(Map.get(heap, id))
    new_mem = estimate_memory(value)
    delta = max(new_mem - old_mem, 0)

    # Invalidate any cached tuple form for this heap id.  Every
    # mutation of a Python list goes through here (`.append`,
    # `.extend`, slice assignment, subscript assignment, etc.), so
    # invalidating centrally lets `eval_subscript` rely on the
    # cache being fresh without touching the 200+ construction
    # sites.  Missing entries are a no-op.
    cache = if Map.has_key?(cache, id), do: Map.delete(cache, id), else: cache

    %{
      ctx
      | heap: Map.put(heap, id, value),
        memory_bytes: ctx.memory_bytes + delta,
        list_index_cache: cache
    }
  end

  @doc """
  Returns true if `value` is a heap reference.
  """
  @spec ref?(term()) :: boolean()
  def ref?({:ref, _}), do: true
  def ref?(_), do: false

  @doc """
  Extracts the ref ID from a `{:ref, id}` tuple.
  """
  @spec ref_id({:ref, non_neg_integer()}) :: non_neg_integer()
  def ref_id({:ref, id}), do: id

  @doc """
  Opens a file handle, returning `{handle_id, ctx}`.
  """
  @spec open_handle(t(), String.t(), :read | :write | :append) ::
          {:ok, non_neg_integer(), t()} | {:error, String.t()}
  def open_handle(%__MODULE__{filesystem: nil}, _path, _mode) do
    {:error, "IOError: no filesystem configured"}
  end

  def open_handle(%__MODULE__{filesystem: fs} = ctx, path, mode) do
    mod = fs.__struct__

    case mode do
      :read ->
        case mod.read(fs, path) do
          {:ok, content} ->
            id = ctx.next_handle
            handle = %{path: path, mode: :read, buffer: content, pos: 0}
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
      {:ok, %{mode: :read, buffer: content} = handle} ->
        pos = Map.get(handle, :pos, 0)
        rest = binary_part(content, pos, byte_size(content) - pos)
        handle = Map.put(handle, :pos, byte_size(content))
        ctx = %{ctx | handles: Map.put(handles, id, handle)}
        ctx = record(ctx, :file_op, {:read, id, byte_size(rest)})
        {:ok, rest, ctx}

      {:ok, _} ->
        {:error, "IOError: not readable"}

      :error ->
        {:error, "ValueError: I/O operation on closed file"}
    end
  end

  @doc """
  Reads at most `n` characters from an open read handle, advancing its
  read position by the bytes consumed.
  """
  @spec read_handle(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t(), t()} | {:error, String.t()}
  def read_handle(%__MODULE__{handles: handles} = ctx, id, n)
      when is_integer(n) and n >= 0 do
    case Map.fetch(handles, id) do
      {:ok, %{mode: :read, buffer: content} = handle} ->
        pos = Map.get(handle, :pos, 0)
        rest = binary_part(content, pos, byte_size(content) - pos)
        chunk = String.slice(rest, 0, n)
        handle = Map.put(handle, :pos, pos + byte_size(chunk))
        ctx = %{ctx | handles: Map.put(handles, id, handle)}
        ctx = record(ctx, :file_op, {:read, id, byte_size(chunk)})
        {:ok, chunk, ctx}

      {:ok, _} ->
        {:error, "IOError: not readable"}

      :error ->
        {:error, "ValueError: I/O operation on closed file"}
    end
  end

  @doc """
  Reads a single line (up to and including the next newline) from an
  open read handle, advancing its read position. Returns `""` at EOF.
  """
  @spec readline_handle(t(), non_neg_integer()) :: {:ok, String.t(), t()} | {:error, String.t()}
  def readline_handle(%__MODULE__{handles: handles} = ctx, id) do
    case Map.fetch(handles, id) do
      {:ok, %{mode: :read, buffer: content} = handle} ->
        pos = Map.get(handle, :pos, 0)
        {line, new_pos} = take_line(content, pos)
        handle = Map.put(handle, :pos, new_pos)
        ctx = %{ctx | handles: Map.put(handles, id, handle)}
        ctx = record(ctx, :file_op, {:read, id, byte_size(line)})
        {:ok, line, ctx}

      {:ok, _} ->
        {:error, "IOError: not readable"}

      :error ->
        {:error, "ValueError: I/O operation on closed file"}
    end
  end

  @doc """
  Reads all remaining lines from an open read handle, each preserving
  its trailing newline, advancing the read position to EOF.
  """
  @spec readlines_handle(t(), non_neg_integer()) ::
          {:ok, [String.t()], t()} | {:error, String.t()}
  def readlines_handle(%__MODULE__{} = ctx, id) do
    case read_handle(ctx, id) do
      {:ok, rest, ctx} -> {:ok, lines_with_newlines(rest), ctx}
      {:error, _} = err -> err
    end
  end

  @spec take_line(String.t(), non_neg_integer()) :: {String.t(), non_neg_integer()}
  defp take_line(content, pos) do
    size = byte_size(content)

    if pos >= size do
      {"", pos}
    else
      rest = binary_part(content, pos, size - pos)

      case :binary.match(rest, "\n") do
        {idx, 1} -> {binary_part(rest, 0, idx + 1), pos + idx + 1}
        :nomatch -> {rest, size}
      end
    end
  end

  @spec lines_with_newlines(String.t()) :: [String.t()]
  defp lines_with_newlines(""), do: []

  defp lines_with_newlines(str) do
    case str |> String.split("\n") |> Enum.reverse() do
      ["" | rest_rev] ->
        rest_rev |> Enum.reverse() |> Enum.map(&(&1 <> "\n"))

      [last | rest_rev] ->
        (rest_rev |> Enum.reverse() |> Enum.map(&(&1 <> "\n"))) ++ [last]
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
  def close_handle(%__MODULE__{handles: handles, filesystem: fs} = ctx, id) do
    case Map.fetch(handles, id) do
      {:ok, %{mode: mode, path: path, buffer: buffer}} when mode in [:write, :append] ->
        case fs.__struct__.write(fs, path, buffer, mode) do
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
  Creates a new generator iterator, returning the iterator token and
  updated context.

  The generator has been pre-run to its first yield. The pool entry
  carries the *queued* yield value (returned by the first `next` /
  first for-loop iteration without resuming) plus the continuation
  needed to advance to subsequent yields.
  """
  @spec new_generator_iterator(t(), term(), [term()], term()) ::
          {{:iterator, non_neg_integer()}, t()}
  def new_generator_iterator(
        %__MODULE__{iterators: iters, next_iterator_id: id} = ctx,
        first_val,
        cont,
        gen_env
      ) do
    entry = {:gen_pending, first_val, cont, gen_env}
    ctx = %{ctx | iterators: Map.put(iters, id, entry), next_iterator_id: id + 1}
    {{:iterator, id}, ctx}
  end

  @doc """
  Inspects an iterator's stored entry without mutating state.
  Returns `nil` for unknown ids.
  """
  @spec iter_entry(t(), non_neg_integer()) :: term() | nil
  def iter_entry(%__MODULE__{iterators: iters}, id), do: Map.get(iters, id)

  @doc """
  Marks a generator iterator as exhausted.
  """
  @spec mark_iter_exhausted(t(), non_neg_integer()) :: t()
  def mark_iter_exhausted(%__MODULE__{iterators: iters} = ctx, id) do
    %{ctx | iterators: Map.put(iters, id, :gen_done)}
  end

  @doc """
  Marks a generator iterator as exhausted and records the body's
  return value.  CPython's `StopIteration(value)` semantics — used
  by `await` to surface the inner coroutine's return as the
  expression's value, and by `yield from` to propagate it up.
  """
  @spec mark_iter_done_with_value(t(), non_neg_integer(), term()) :: t()
  def mark_iter_done_with_value(%__MODULE__{iterators: iters} = ctx, id, return_value) do
    %{ctx | iterators: Map.put(iters, id, {:gen_done, return_value})}
  end

  @doc """
  Creates a fresh, unstarted coroutine iterator.  The body is staged
  in a `:gen_unstarted` pool entry; the first advance runs the body
  in `:lazy_iter` mode up to the first yield (or to completion).

  CPython semantics: calling an `async def` does NOT run the body;
  the body runs only when the coroutine is driven (`await` /
  `asyncio.run`).
  """
  @spec new_unstarted_coroutine_iterator(t(), [term()], term()) ::
          {{:iterator, non_neg_integer()}, t()}
  def new_unstarted_coroutine_iterator(
        %__MODULE__{iterators: iters, next_iterator_id: id} = ctx,
        body,
        gen_env
      ) do
    entry = {:gen_unstarted, body, gen_env}
    ctx = %{ctx | iterators: Map.put(iters, id, entry), next_iterator_id: id + 1}
    {{:iterator, id}, ctx}
  end

  @doc """
  Creates an iterator pool entry for an awaitable-capability call.

  Takes a `sentinel_builder` closure that receives the freshly-allocated
  `cap_id` and returns the sentinel to store.  This lets the caller
  embed the id in the sentinel without needing to re-stamp the entry
  after allocation — the chicken-and-egg from when this function took a
  pre-built sentinel goes away.

  Uses the same `:gen_awaiting_send` shape as Python `r = yield X`
  generators — both protocols pause an iter waiting for a value to be
  sent in.  The difference is in advance behavior, which dispatches on
  the value's shape: a `coroutine_signal()` (capability sentinel)
  surfaces and waits for the trampoline to call
  `Pyex.Interpreter.Invocation.resume_capability/4`; a `pyvalue()`
  auto-advances with `nil` (Python `next(g)` semantics).
  """
  @spec new_awaiting_capability_iterator(
          t(),
          (non_neg_integer() -> term()),
          [term()],
          term()
        ) :: {{:iterator, non_neg_integer()}, t()}
  def new_awaiting_capability_iterator(
        %__MODULE__{iterators: iters, next_iterator_id: id} = ctx,
        sentinel_builder,
        cont,
        gen_env
      )
      when is_function(sentinel_builder, 1) do
    entry = {:gen_awaiting_send, sentinel_builder.(id), cont, gen_env}
    ctx = %{ctx | iterators: Map.put(iters, id, entry), next_iterator_id: id + 1}
    {{:iterator, id}, ctx}
  end

  @doc """
  Returns the stored return value for an exhausted generator
  iterator (or `nil` if there isn't one — the bare `:gen_done`
  marker carries no value).
  """
  @spec iter_return_value(t(), non_neg_integer()) :: term()
  def iter_return_value(%__MODULE__{iterators: iters}, id) do
    case Map.get(iters, id) do
      {:gen_done, value} -> value
      _ -> nil
    end
  end

  @doc """
  Updates a generator iterator's pending entry after a successful resume.
  """
  @spec set_gen_pending(t(), non_neg_integer(), term(), [term()], term()) :: t()
  def set_gen_pending(%__MODULE__{iterators: iters} = ctx, id, val, cont, gen_env) do
    %{ctx | iterators: Map.put(iters, id, {:gen_pending, val, cont, gen_env})}
  end

  @doc """
  Records that the generator has yielded `val` via a yield-expression
  (`v = yield val`) and is now waiting for a sent value before continuing.
  Unlike `set_gen_pending/5`, the continuation is NOT run eagerly — it
  will be driven by the next `next()` or `send()` call.
  """
  @spec set_gen_awaiting_send(t(), non_neg_integer(), term(), [term()], term()) :: t()
  def set_gen_awaiting_send(%__MODULE__{iterators: iters} = ctx, id, val, cont, gen_env) do
    %{ctx | iterators: Map.put(iters, id, {:gen_awaiting_send, val, cont, gen_env})}
  end

  @doc """
  Advances a plain list iterator, returning the next item
  or `:exhausted` if the iterator is empty.

  For generator iterators, returns the queued yield value plus the
  continuation needed to advance further. The caller resumes the
  generator (using `Pyex.Interpreter.resume_generator/3`) and updates
  the pool via `set_gen_pending/5` or `mark_iter_exhausted/2`.
  """
  @spec iter_next(t(), non_neg_integer()) ::
          {:ok, term(), t()}
          | :exhausted
          | {:instance, term()}
          | {:gen_pending, term(), [term()], term()}
          | {:gen_awaiting_send, term(), [term()], term()}
          | {:gen_unstarted, [term()], term()}
  def iter_next(%__MODULE__{iterators: iters} = ctx, id) do
    case Map.get(iters, id) do
      {:list, [item | rest]} ->
        ctx = %{ctx | iterators: Map.put(iters, id, {:list, rest})}
        {:ok, item, ctx}

      {:list, []} ->
        :exhausted

      {:instance, inst} ->
        {:instance, inst}

      {:gen_pending, val, cont, gen_env} ->
        {:gen_pending, val, cont, gen_env}

      {:gen_awaiting_send, val, cont, gen_env} ->
        {:gen_awaiting_send, val, cont, gen_env}

      {:gen_unstarted, body, gen_env} ->
        {:gen_unstarted, body, gen_env}

      :gen_done ->
        :exhausted

      {:gen_done, _value} ->
        # Generator completed with a captured return value (PEP 380
        # `StopIteration(value)`).  iter_next reports `:exhausted`
        # uniformly; callers that need the value pull it via
        # `iter_return_value/2`.
        :exhausted

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
