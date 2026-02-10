alias Pyex.{Lexer, Parser, Interpreter, Builtins, Ctx, Env}

programs = [
  {"fizzbuzz_100",
   """
   result = ""
   for i in range(1, 101):
       if i % 15 == 0:
           result = result + "FizzBuzz "
       elif i % 3 == 0:
           result = result + "Fizz "
       elif i % 5 == 0:
           result = result + "Buzz "
       else:
           result = result + str(i) + " "
   len(result)
   """},
  {"while_loop_100",
   """
   i = 0
   total = 0
   while i < 100:
       total = total + i
       i = i + 1
   total
   """},
  {"for_range_100",
   """
   total = 0
   for i in range(100):
       total = total + i
   total
   """}
]

n = 2000

IO.puts("Overhead breakdown (avg of #{n} runs):\n")

IO.puts(
  String.pad_trailing("benchmark", 20) <>
    String.pad_leading("e2e", 8) <>
    String.pad_leading("no-otel", 8) <>
    String.pad_leading("eval", 8) <>
    String.pad_leading("no-ctx", 8) <>
    String.pad_leading("otel", 8) <>
    String.pad_leading("ctx", 8) <>
    String.pad_leading("lex+parse", 10)
)

IO.puts(String.duplicate("-", 78))

for {name, source} <- programs do
  {:ok, tokens} = Lexer.tokenize(source)
  {:ok, ast} = Parser.parse(tokens)
  env = Builtins.env()

  e2e_us = elem(:timer.tc(fn -> for _ <- 1..n, do: Pyex.run!(source) end), 0) |> div(n)

  no_otel_us =
    elem(
      :timer.tc(fn ->
        for _ <- 1..n do
          {:ok, tokens} = Lexer.tokenize(source)
          {:ok, ast} = Parser.parse(tokens)
          ctx = Ctx.new()
          ctx = %{ctx | compute_ns: 0, compute_started_at: System.monotonic_time(:nanosecond)}
          Interpreter.run_with_ctx(ast, env, ctx)
        end
      end),
      0
    )
    |> div(n)

  eval_us = elem(:timer.tc(fn -> for _ <- 1..n, do: Interpreter.run(ast) end), 0) |> div(n)

  eval_no_ctx_us =
    elem(
      :timer.tc(fn ->
        for _ <- 1..n do
          Interpreter.run_with_ctx(ast, env, %Ctx{mode: :live})
        end
      end),
      0
    )
    |> div(n)

  otel_overhead = e2e_us - no_otel_us
  ctx_overhead = eval_us - eval_no_ctx_us
  lex_parse = no_otel_us - eval_us

  IO.puts(
    String.pad_trailing(name, 20) <>
      String.pad_leading("#{e2e_us}μs", 8) <>
      String.pad_leading("#{no_otel_us}μs", 8) <>
      String.pad_leading("#{eval_us}μs", 8) <>
      String.pad_leading("#{eval_no_ctx_us}μs", 8) <>
      String.pad_leading("#{otel_overhead}μs", 8) <>
      String.pad_leading("#{ctx_overhead}μs", 8) <>
      String.pad_leading("#{lex_parse}μs", 10)
  )
end

IO.puts("\n\nCtx.record overhead measurement:\n")

{:ok, tokens} = Lexer.tokenize(programs |> List.keyfind("fizzbuzz_100", 0) |> elem(1))
{:ok, ast} = Parser.parse(tokens)
env = Builtins.env()

ctx_live = Ctx.new()

record_us =
  elem(
    :timer.tc(fn ->
      for _ <- 1..100_000 do
        ctx = %Ctx{mode: :live, step: 0, log: []}
        ctx = Ctx.record(ctx, :assign, {:x})
        ctx = Ctx.record(ctx, :branch, {true})
        ctx = Ctx.record(ctx, :loop_iter, {1})
        ctx = Ctx.record(ctx, :assign, {:y})
        ctx = Ctx.record(ctx, :call_enter, {1})
        Ctx.record(ctx, :call_exit, {42})
      end
    end),
    0
  )

IO.puts(
  "6 Ctx.record calls x100k: #{record_us}μs total, #{Float.round(record_us / 100_000, 2)}μs per batch of 6"
)

check_us =
  elem(
    :timer.tc(fn ->
      ctx = %Ctx{mode: :live, timeout_ns: nil}

      for _ <- 1..100_000 do
        Ctx.check_deadline(ctx)
      end
    end),
    0
  )

IO.puts(
  "Ctx.check_deadline(nil timeout) x100k: #{check_us}μs total, #{Float.round(check_us / 100_000, 3)}μs each"
)

check_active_us =
  elem(
    :timer.tc(fn ->
      ctx = %Ctx{
        mode: :live,
        timeout_ns: 60_000_000_000,
        compute_ns: 0,
        compute_started_at: System.monotonic_time(:nanosecond)
      }

      for _ <- 1..100_000 do
        Ctx.check_deadline(ctx)
      end
    end),
    0
  )

IO.puts(
  "Ctx.check_deadline(active timeout) x100k: #{check_active_us}μs total, #{Float.round(check_active_us / 100_000, 3)}μs each"
)

IO.puts("\n\nEnv.get / Env.smart_put overhead:\n")

single_scope = Env.new() |> Env.put("x", 1) |> Env.put("y", 2) |> Env.put("z", 3)
two_scope = single_scope |> Env.push_scope() |> Env.put("a", 10)
three_scope = two_scope |> Env.push_scope() |> Env.put("b", 20)

for {label, env} <- [
      {"1 scope", single_scope},
      {"2 scopes", two_scope},
      {"3 scopes", three_scope}
    ] do
  get_us =
    elem(
      :timer.tc(fn ->
        for _ <- 1..100_000, do: Env.get(env, "x")
      end),
      0
    )

  put_us =
    elem(
      :timer.tc(fn ->
        for _ <- 1..100_000, do: Env.smart_put(env, "x", 42)
      end),
      0
    )

  IO.puts(
    "#{label}: get x100k=#{get_us}μs (#{Float.round(get_us / 100_000, 3)}μs each)  smart_put x100k=#{put_us}μs (#{Float.round(put_us / 100_000, 3)}μs each)"
  )
end

IO.puts("\n\nOTel span overhead:\n")

require OpenTelemetry.Tracer, as: Tracer

otel_us =
  elem(
    :timer.tc(fn ->
      for _ <- 1..10_000 do
        Tracer.with_span "test.span" do
          :ok
        end
      end
    end),
    0
  )

IO.puts(
  "OTel with_span (empty) x10k: #{otel_us}μs total, #{Float.round(otel_us / 10_000, 2)}μs each"
)

nested_otel_us =
  elem(
    :timer.tc(fn ->
      for _ <- 1..10_000 do
        Tracer.with_span "outer" do
          Tracer.with_span "inner1" do
            Tracer.with_span "inner2" do
              :ok
            end
          end
        end
      end
    end),
    0
  )

IO.puts(
  "OTel 3x nested with_span x10k: #{nested_otel_us}μs total, #{Float.round(nested_otel_us / 10_000, 2)}μs each"
)
