defmodule Pyex.Agent do
  @moduledoc """
  LLM agent loop with a Python execution tool.

  Sends messages to the Anthropic API, lets the model call
  `run_python` to execute code in our interpreter, feeds
  back results, and loops until the model produces a final
  text response.

  State (filesystem, execution context) persists across tool
  calls within a session. Every execution is fully logged.
  """

  alias Pyex.{Ctx, Filesystem.Memory}

  @api_url "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-4-5-20250929"
  @max_tokens 4096
  @max_turns 20

  @tool %{
    "name" => "run_python",
    "description" =>
      "Execute a Python program and return its result. " <>
        "The code runs in a sandboxed Python 3 interpreter with an in-memory filesystem. " <>
        "The tool returns the value of the last expression. " <>
        "Use print() for side effects; its output is captured. " <>
        "File I/O: open('path', 'r'|'w'|'a'), f.read(), f.write(s), f.close(). " <>
        "Available stdlib: import requests, import json, import math, import os. " <>
        "HTTP: requests.get(url), requests.post(url, json={...}, headers={...}). " <>
        "The filesystem persists across tool calls within this session.",
    "input_schema" => %{
      "type" => "object",
      "properties" => %{
        "code" => %{
          "type" => "string",
          "description" => "Python 3 source code to execute"
        }
      },
      "required" => ["code"]
    }
  }

  @type state :: %{
          filesystem: Memory.t(),
          call_count: non_neg_integer(),
          total_events: non_neg_integer()
        }

  @type message :: %{String.t() => term()}

  @doc """
  Runs the agent loop with the given user prompt.

  Options:
  - `:filesystem` -- initial Memory filesystem (default: empty)

  Returns `{:ok, final_text, state}` or `{:error, reason}`.
  """
  @spec run(String.t(), keyword()) :: {:ok, String.t(), state()} | {:error, String.t()}
  def run(prompt, opts \\ []) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || raise "ANTHROPIC_API_KEY not set"
    fs = Keyword.get(opts, :filesystem, Memory.new())

    state = %{
      filesystem: fs,
      call_count: 0,
      total_events: 0
    }

    messages = [%{"role" => "user", "content" => prompt}]

    log(:session_start, %{prompt: prompt, fs_files: Map.keys(state.filesystem.files)})
    loop(messages, api_key, state, 0)
  end

  @spec loop([message()], String.t(), state(), non_neg_integer()) ::
          {:ok, String.t(), state()} | {:error, String.t()}
  defp loop(_messages, _api_key, _state, turn) when turn >= @max_turns do
    log(:error, %{reason: "exceeded #{@max_turns} turns"})
    {:error, "agent exceeded #{@max_turns} turns"}
  end

  defp loop(messages, api_key, state, turn) do
    log(:turn_start, %{turn: turn + 1})

    t0 = System.monotonic_time(:millisecond)

    case call_api(messages, api_key) do
      {:ok, response} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        log(:api_response, %{elapsed_ms: elapsed, stop_reason: response["stop_reason"]})
        handle_response(response, messages, api_key, state, turn)

      {:error, reason} ->
        log(:api_error, %{reason: reason})
        {:error, "API call failed: #{inspect(reason)}"}
    end
  end

  @spec handle_response(map(), [message()], String.t(), state(), non_neg_integer()) ::
          {:ok, String.t(), state()} | {:error, String.t()}
  defp handle_response(
         %{"content" => content, "stop_reason" => stop_reason},
         messages,
         api_key,
         state,
         turn
       ) do
    text_parts =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])

    for text <- text_parts, text != "" do
      log(:assistant_text, %{text: text})
    end

    tool_uses = Enum.filter(content, &(&1["type"] == "tool_use"))

    cond do
      stop_reason == "tool_use" and tool_uses != [] ->
        {tool_results, state} =
          Enum.map_reduce(tool_uses, state, fn tool_use, st ->
            execute_tool(tool_use, st)
          end)

        assistant_msg = %{"role" => "assistant", "content" => content}
        user_msg = %{"role" => "user", "content" => tool_results}

        loop(messages ++ [assistant_msg, user_msg], api_key, state, turn + 1)

      true ->
        final = Enum.join(text_parts, "\n")
        log(:session_end, %{state: format_state(state)})
        {:ok, final, state}
    end
  end

  defp handle_response(response, _messages, _api_key, _state, _turn) do
    {:error, "unexpected response shape: #{inspect(response)}"}
  end

  @spec execute_tool(map(), state()) :: {map(), state()}
  defp execute_tool(%{"id" => id, "name" => "run_python", "input" => %{"code" => code}}, state) do
    call_num = state.call_count + 1
    log(:tool_call, %{call: call_num, code: code})

    t0 = System.monotonic_time(:millisecond)
    {output, result, new_state} = capture_and_run(code, state)
    elapsed = System.monotonic_time(:millisecond) - t0

    new_state = %{new_state | call_count: call_num}

    result_text =
      case result do
        {:ok, value} ->
          parts = [output, format_value(value)] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")

          log(:tool_result, %{
            call: call_num,
            elapsed_ms: elapsed,
            value: format_value(value),
            stdout_bytes: byte_size(output),
            events: new_state.total_events,
            fs_files: Map.keys(new_state.filesystem.files)
          })

          parts

        {:error, reason} ->
          parts = [output, "Error: #{reason}"] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
          log(:tool_error, %{call: call_num, elapsed_ms: elapsed, error: reason})
          parts
      end

    msg = %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => result_text
    }

    {msg, new_state}
  end

  defp execute_tool(%{"id" => id, "name" => name}, state) do
    log(:tool_error, %{error: "unknown tool '#{name}'"})

    msg = %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => "Error: unknown tool '#{name}'",
      "is_error" => true
    }

    {msg, state}
  end

  @spec capture_and_run(String.t(), state()) ::
          {String.t(), {:ok, Pyex.Interpreter.pyvalue()} | {:error, String.t()}, state()}
  defp capture_and_run(code, state) do
    original_gl = Process.group_leader()
    {:ok, capture} = StringIO.open("")
    Process.group_leader(self(), capture)

    ctx = Ctx.new(filesystem: state.filesystem)

    {result, new_state} =
      try do
        case Pyex.run(code, ctx) do
          {:ok, value, ctx} ->
            event_count = length(Ctx.events(ctx))

            new_state = %{
              state
              | filesystem: ctx.filesystem,
                total_events: state.total_events + event_count
            }

            {{:ok, value}, new_state}

          {:error, reason} ->
            {{:error, reason}, state}
        end
      rescue
        e ->
          {{:error, Exception.message(e)}, state}
      after
        Process.group_leader(self(), original_gl)
      end

    {_, output} = StringIO.contents(capture)
    StringIO.close(capture)

    {String.trim_trailing(output), result, new_state}
  end

  @spec format_value(Pyex.Interpreter.pyvalue()) :: String.t()
  defp format_value(nil), do: ""
  defp format_value(value) when is_binary(value), do: inspect(value)
  defp format_value(true), do: "True"
  defp format_value(false), do: "False"
  defp format_value(value), do: inspect(value)

  @spec format_state(state()) :: String.t()
  defp format_state(state) do
    files = Map.keys(state.filesystem.files)
    file_count = length(files)

    file_details =
      Enum.map(state.filesystem.files, fn {path, content} ->
        "  #{path} (#{byte_size(content)} bytes)"
      end)
      |> Enum.join("\n")

    """
    calls=#{state.call_count} events=#{state.total_events} files=#{file_count}
    #{file_details}\
    """
    |> String.trim_trailing()
  end

  @spec log(atom(), map()) :: :ok
  defp log(event, data) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    prefix =
      case event do
        :session_start ->
          "\n#{IO.ANSI.cyan()}=== SESSION START ===#{IO.ANSI.reset()}"

        :session_end ->
          "\n#{IO.ANSI.cyan()}=== SESSION END ===#{IO.ANSI.reset()}"

        :turn_start ->
          "\n#{IO.ANSI.yellow()}--- Turn #{data.turn} ---#{IO.ANSI.reset()}"

        :api_response ->
          "  #{IO.ANSI.faint()}api #{data.elapsed_ms}ms stop=#{data.stop_reason}#{IO.ANSI.reset()}"

        :api_error ->
          "  #{IO.ANSI.red()}api error: #{inspect(data.reason)}#{IO.ANSI.reset()}"

        :assistant_text ->
          "\n#{IO.ANSI.green()}[assistant]#{IO.ANSI.reset()} #{data.text}"

        :tool_call ->
          "\n#{IO.ANSI.blue()}[python ##{data.call}]#{IO.ANSI.reset()}\n#{data.code}\n#{IO.ANSI.faint()}---#{IO.ANSI.reset()}"

        :tool_result ->
          "#{IO.ANSI.green()}[result ##{data.call}]#{IO.ANSI.reset()} #{data.value} #{IO.ANSI.faint()}(#{data.elapsed_ms}ms, #{data.events} events, stdout=#{data.stdout_bytes}b, fs=#{inspect(data.fs_files)})#{IO.ANSI.reset()}"

        :tool_error ->
          "#{IO.ANSI.red()}[error ##{data.call}]#{IO.ANSI.reset()} #{data.error}"

        :error ->
          "#{IO.ANSI.red()}[error]#{IO.ANSI.reset()} #{data.reason}"
      end

    IO.puts("#{IO.ANSI.faint()}#{ts}#{IO.ANSI.reset()} #{prefix}")
    :ok
  end

  @spec call_api([message()], String.t()) :: {:ok, map()} | {:error, term()}
  defp call_api(messages, api_key) do
    body = %{
      "model" => @model,
      "max_tokens" => @max_tokens,
      "system" =>
        "You are a helpful assistant with access to a Python 3 interpreter. " <>
          "Use the run_python tool to execute code when needed. " <>
          "The interpreter supports: variables, arithmetic, strings, lists, dicts, tuples, " <>
          "functions (def/return with default args), lambda expressions, " <>
          "if/elif/else, while, for loops, try/except, break, continue, " <>
          "list comprehensions, ternary (x if cond else y), f-strings, " <>
          "triple-quoted strings, multiple assignment (a, b = 1, 2), " <>
          "slice notation (list[1:3], str[::-1]), decorators, " <>
          "keyword arguments (f(x=1)), is/is not operators. " <>
          "Imports: import requests, import json, import math, import os. " <>
          "HTTP: requests.get(url), requests.post(url, json={...}, headers={...}). " <>
          "os.environ[\"KEY\"] reads environment variables. " <>
          "Builtins: len, range, print, str, int, float, type, abs, min, max, " <>
          "sum, sorted, reversed, enumerate, zip, bool, list, dict, tuple, " <>
          "isinstance, round, open, input. " <>
          "String methods: upper, lower, strip, lstrip, rstrip, split, join, replace, " <>
          "startswith, endswith, find, count, format, isdigit, isalpha, isalnum, " <>
          "title, capitalize. " <>
          "List methods: append, extend, insert, remove, pop, sort, reverse, clear, " <>
          "index, count, copy. " <>
          "Dict methods: get, keys, values, items, pop, update, setdefault, clear, copy. " <>
          "FILE I/O: open(path, mode) where mode is 'r', 'w', or 'a'. " <>
          "f.read() returns content, f.write(s) writes, f.close() flushes to disk. " <>
          "The filesystem persists across tool calls in this session. " <>
          "It does NOT support: classes, *args/**kwargs, with statements, generators, " <>
          "from X import Y, import X as Y, async/await, or yield. " <>
          "Do NOT use urllib -- use the requests module instead.",
      "tools" => [@tool],
      "messages" => messages
    }

    case Req.post(@api_url,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
