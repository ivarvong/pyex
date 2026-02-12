[
  # call_dunder wraps {:exception, _} as a return value inside {:ok, ...}
  # which dialyzer sees as impossible since {:exception, _} is a signal, not a pyvalue.
  # This is a deliberate design choice for distinguishing "not found" from "found but errored".
  {"lib/pyex/interpreter.ex", :pattern_match},
  # call_function returns {:mutate, ...} tuples at runtime that Dialyzer
  # cannot track through the union type -- same issue as the main interpreter.
  {"lib/pyex/interpreter/unittest.ex", :pattern_match},
  # Dialyzer cannot narrow [pyvalue()] to [binary()] through the `when is_binary(text)` guard,
  # so it concludes only the catch-all exception clause is reachable. False positive.
  {"lib/pyex/stdlib/markdown.ex", :invalid_contract},
  # unwrap_response and unwrap_stream_response return partial response maps (without telemetry).
  # The telemetry field is added by the caller via Map.put, which Dialyzer cannot track.
  {"lib/pyex/lambda.ex", :invalid_contract},
  # MapSet is an opaque type. Dialyzer complains when it appears in struct fields
  # because it cannot see through the opaque boundary. The capabilities MapSet is
  # used correctly via MapSet.member?/2 and MapSet.new/1 -- these are false positives.
  {"lib/pyex/interpreter.ex", :call_without_opaque},
  {"lib/pyex/stdlib/jinja2.ex", :call_without_opaque},
  # The with-statement eval clause calls eval/3 on the context manager expression,
  # but Dialyzer cannot narrow the union type through pattern matching on
  # {:with, _, [expr, as_name, body]} and thinks expr could be an atom.
  {"lib/pyex/interpreter.ex", :call},
  # extract_exception_type_name/1 and with_update_cm/3 are called from the
  # {:with, ...} eval clause but Dialyzer's call graph analysis cannot trace
  # through the complex union-typed control flow. Both are genuinely reachable.
  {"lib/pyex/interpreter.ex", :unused_fun},
  # bound_kw/2 wraps a method function with receiver binding. Dialyzer traces
  # through the single call site (list_sort/3) and infers the args pattern must
  # be [], but the anonymous function accepts any args list. False positive.
  {"lib/pyex/methods.ex", :no_return}
]
