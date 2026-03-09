defmodule Pyex.Entropy do
  @moduledoc """
  Shannon entropy primitives for binary analysis and secret detection.
  """

  @type hit :: %{
          offset: non_neg_integer(),
          entropy: float(),
          window: binary(),
          matcher: atom() | nil
        }

  @default_window_size 64
  @default_threshold 5.8

  @builtin_matchers %{
    aws_access_key: ~r/AKIA[0-9A-Z]{16}/,
    aws_secret_key:
      ~r/(?i)aws(.{0,20})?(secret|access)?(.{0,20})?(key)?\s*[:=]\s*["']?[A-Za-z0-9\/+=]{40}["']?/,
    google_api_key: ~r/AIza[0-9A-Za-z\-_]{35}/,
    azure_storage_connection_string:
      ~r/DefaultEndpointsProtocol=https;AccountName=[^;]+;AccountKey=[A-Za-z0-9+\/=]+;EndpointSuffix=core\.windows\.net/,
    github_token: ~r/ghp_[A-Za-z0-9]{36}/,
    github_fine_grained: ~r/github_pat_[A-Za-z0-9_]{82}/,
    openai_key: ~r/sk-(?!(?:ant-|or-v1-))(?:proj-)?[A-Za-z0-9_-]{20,}/,
    anthropic_key: ~r/sk-ant-[A-Za-z0-9_-]{20,}/,
    openrouter_key: ~r/sk-or-v1-[A-Za-z0-9_-]{20,}/,
    groq_key: ~r/gsk_[A-Za-z0-9]{20,}/,
    huggingface_token: ~r/hf_[A-Za-z0-9]{30,}/,
    stripe_live: ~r/sk_live_[A-Za-z0-9]{24,}/,
    stripe_test: ~r/sk_test_[A-Za-z0-9]{24,}/,
    slack_token: ~r/xox[bpors]-[A-Za-z0-9\-]{10,}/,
    private_key: ~r/-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----/,
    generic_secret: ~r/(?i)(secret|password|token|api_key|apikey)\s*[:=]\s*["'][^\s"']{8,}["']/
  }

  @doc """
  Computes the Shannon entropy of a binary in bits per byte.

  ## Examples

      iex> Pyex.Entropy.shannon("aaaa")
      0.0

      iex> Pyex.Entropy.shannon("abcd")
      2.0

  """
  @spec shannon(binary()) :: float()
  def shannon(<<>>), do: 0.0

  def shannon(binary) when is_binary(binary) do
    size = byte_size(binary)

    binary
    |> byte_freqs()
    |> entropy_from_freqs(size)
  end

  @doc """
  Returns the builtin matcher map. Useful for inspection or selective inclusion.

  ## Examples

      iex> Map.has_key?(Pyex.Entropy.builtin_matchers(), :openai_key)
      true

  """
  @spec builtin_matchers() :: %{atom() => Regex.t()}
  def builtin_matchers, do: @builtin_matchers

  @doc """
  Scans a binary with a sliding window and optional regex matchers.

  Returns a list of `%{offset, entropy, window, matcher}` maps. A hit fires
  when *either* condition is met:

    * window entropy >= threshold
    * a matcher regex matches the window

  When both match, the hit includes the matcher name. When only entropy
  triggers, `matcher` is `nil`.

  ## Options

    * `:window_size` - sliding window in bytes (default: #{@default_window_size})
    * `:threshold` - minimum entropy in bits to report (default: #{@default_threshold})
    * `:matchers` - `%{atom() => Regex.t()}` of named patterns (default: `%{}`)
    * `:builtins` - include builtin matchers (default: `false`)

  ## Examples

      iex> token = "tok_" <> String.duplicate("a", 24)
      iex> input = ~s(config = {api_key: ") <> token <> ~s("})
      iex> matchers = %{custom_token: ~r/tok_[A-Za-z0-9]{24,}/}
      iex> hits = Pyex.Entropy.scan(input, matchers: matchers, threshold: 99.0, window_size: 256)
      iex> Enum.any?(hits, &(&1.matcher == :custom_token))
      true

  """
  @spec scan(binary(), keyword()) :: [hit()]
  def scan(binary, opts \\ []) when is_binary(binary) do
    window_size = normalize_window_size!(Keyword.get(opts, :window_size, @default_window_size))
    threshold = normalize_threshold!(Keyword.get(opts, :threshold, @default_threshold))
    user_matchers = normalize_matchers!(Keyword.get(opts, :matchers, %{}))
    builtins = if Keyword.get(opts, :builtins, false), do: @builtin_matchers, else: %{}
    matchers = Map.merge(builtins, user_matchers)

    case byte_size(binary) do
      0 -> []
      size when size < window_size -> collect_single(binary, threshold, matchers)
      _size -> do_scan(binary, window_size, threshold, matchers)
    end
  end

  # -- Private --

  defp do_scan(binary, window_size, threshold, matchers) do
    size = byte_size(binary)

    init_freqs =
      for <<byte <- binary_part(binary, 0, window_size)>>, reduce: %{} do
        acc -> Map.update(acc, byte, 1, &(&1 + 1))
      end

    {_freqs, hits} =
      1..(size - window_size)//1
      |> Enum.reduce(
        {init_freqs, collect(binary, 0, init_freqs, window_size, threshold, matchers)},
        fn offset, {freqs, hits} ->
          entering = :binary.at(binary, offset + window_size - 1)
          leaving = :binary.at(binary, offset - 1)

          freqs =
            freqs
            |> Map.update(entering, 1, &(&1 + 1))
            |> decrement_or_remove(leaving)

          {freqs, collect(binary, offset, freqs, window_size, threshold, matchers) ++ hits}
        end
      )

    hits
    |> Enum.reverse()
    |> dedupe()
  end

  defp collect_single(binary, threshold, matchers) do
    collect(binary, 0, byte_freqs(binary), byte_size(binary), threshold, matchers)
  end

  defp collect(binary, offset, freqs, window_size, threshold, matchers) do
    window = binary_part(binary, offset, window_size)
    h = entropy_from_freqs(freqs, window_size)
    matched = find_matchers(window, matchers)

    cond do
      matched != [] ->
        Enum.map(matched, fn name ->
          %{offset: offset, entropy: h, window: window, matcher: name}
        end)

      h >= threshold ->
        [%{offset: offset, entropy: h, window: window, matcher: nil}]

      true ->
        []
    end
  end

  defp find_matchers(_window, matchers) when map_size(matchers) == 0, do: []

  defp find_matchers(window, matchers) do
    for {name, regex} <- matchers, Regex.match?(regex, window), do: name
  end

  defp dedupe(hits) do
    # collapse overlapping windows that matched the same pattern
    hits
    |> Enum.reduce({[], nil}, fn hit, {acc, prev} ->
      if prev && hit.matcher && hit.matcher == prev.matcher &&
           hit.offset - prev.offset < byte_size(prev.window) do
        {acc, prev}
      else
        {[hit | acc], hit}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp byte_freqs(binary) do
    for <<byte <- binary>>, reduce: %{} do
      acc -> Map.update(acc, byte, 1, &(&1 + 1))
    end
  end

  defp entropy_from_freqs(freqs, total) do
    Enum.reduce(freqs, 0.0, fn {_byte, count}, acc ->
      p = count / total
      acc - p * :math.log2(p)
    end)
  end

  defp decrement_or_remove(freqs, byte) do
    case freqs[byte] do
      1 -> Map.delete(freqs, byte)
      n -> Map.put(freqs, byte, n - 1)
    end
  end

  defp normalize_window_size!(window_size) when is_integer(window_size) and window_size > 0,
    do: window_size

  defp normalize_window_size!(_window_size) do
    raise ArgumentError, "window_size must be a positive integer"
  end

  defp normalize_threshold!(threshold) when is_number(threshold), do: threshold * 1.0

  defp normalize_threshold!(_threshold) do
    raise ArgumentError, "threshold must be a number"
  end

  defp normalize_matchers!(matchers) when is_map(matchers), do: matchers

  defp normalize_matchers!(_matchers) do
    raise ArgumentError, "matchers must be a map"
  end
end
