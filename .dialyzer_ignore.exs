[
  # call_function returns {:mutate, ...} tuples at runtime that Dialyzer
  # cannot track through the union type -- same issue as the main interpreter.
  {"lib/pyex/interpreter/unittest.ex", :pattern_match},
  # Dialyzer cannot narrow [pyvalue()] to [binary()] through the `when is_binary(text)` guard,
  # so it concludes only the catch-all exception clause is reachable. False positive.
  {"lib/pyex/stdlib/markdown.ex", :invalid_contract},
  # unwrap_response and unwrap_stream_response return partial response maps (without telemetry).
  # The telemetry field is added by the caller via Map.put, which Dialyzer cannot track.
  {"lib/pyex/lambda.ex", :invalid_contract},
  # call_handler returns {:exception, msg} as a signal alongside normal pyvalues.
  # Dialyzer cannot see {:exception, _} in the pyvalue() type since it is a
  # control-flow signal, not a Python value. The pattern match is reachable at runtime.
  {"lib/pyex/lambda.ex", :pattern_match},
  # MapSet is an opaque type. Dialyzer complains when it appears in struct fields
  # because it cannot see through the opaque boundary. The capabilities MapSet is
  # used correctly via MapSet.member?/2 and MapSet.new/1 -- these are false positives.
  {"lib/pyex/interpreter.ex", :call_without_opaque},
  {"lib/pyex/stdlib/jinja2.ex", :call_without_opaque},
  # The with-statement eval clause calls eval/3 on the context manager expression,
  # but Dialyzer cannot narrow the union type through pattern matching on
  # {:with, _, [expr, as_name, body]} and thinks expr could be an atom.
  {"lib/pyex/interpreter.ex", :call},
  # defaultdict auto-insert returns a 5-tuple {:defaultdict_auto_insert, ...} from
  # eval_subscript. Dialyzer cannot trace this tagged tuple through the case match.
  {"lib/pyex/interpreter.ex", :pattern_match},
  # extract_exception_type_name/1 and with_update_cm/3 are called from the
  # {:with, ...} eval clause but Dialyzer's call graph analysis cannot trace
  # through the complex union-typed control flow. Both are genuinely reachable.
  {"lib/pyex/interpreter.ex", :unused_fun},
  # call_dunder/call_dunder_mut return {:exception, _} inside the {:ok, ...} tuple.
  # {:exception, _} is a control-flow signal, not a pyvalue(), so Dialyzer sees
  # the pattern match as impossible. These are reachable at runtime.
  {"lib/pyex/interpreter/builtin_results.ex", :pattern_match},
  {"lib/pyex/interpreter/iterables.ex", :pattern_match},
  # call_function returns 3- or 4-element tuples at runtime that Dialyzer
  # cannot track through the union type. do_aug_subscript and do_nested_aug_inner
  # are genuinely called from the defaultdict lambda factory handling paths.
  {"lib/pyex/interpreter/assignments.ex", :unused_fun},
  # defaultdict auto-insert returns {:defaultdict_auto_insert, ...} 5-tuple and
  # {:defaultdict_call_needed, ...} from get_subscript_value. Dialyzer cannot
  # trace these tagged tuples through the control flow.
  {"lib/pyex/interpreter/assignments.ex", :pattern_match},
  # lookup_named_key returns {:exception, msg} as an error signal alongside
  # pyvalues. The pattern match in string_format_loop is reachable at runtime.
  {"lib/pyex/interpreter/format.ex", :pattern_match},
  # eval_param_defaults wraps evaluated defaults in {:__evaluated__, val}.
  # Parser.param() type does not include this wrapper, but it is valid at runtime.
  {"lib/pyex/interpreter/call_support.ex", :pattern_match},
  # resume_generator can return {:yielded, val, cont, gen_env, ctx} at runtime
  # (in defer mode). Dialyzer's type inference doesn't fully track this path.
  {"lib/pyex/interpreter/dunder.ex", :pattern_match},
  # do_request currently always returns {:io_call, fn}; the catch-all branch
  # is a defensive guard for future return variants.
  {"lib/pyex/stdlib/requests.ex", :pattern_match_cov},
  # Defensive fallback patterns in json encoding: format_decode_error's
  # catch-all and indent_at's non-integer indent branch are unreachable
  # given the current call sites, but kept as guards for future inputs.
  {"lib/pyex/stdlib/json.ex", :pattern_match_cov},
  # `decimal_round_with_mode/3` accepts `:round_05up` for CPython's
  # ROUND_05UP behaviour, but Dialyzer infers the mode argument as the
  # narrower `Decimal.rounding()` union (which excludes `:round_05up`)
  # because it traces through `Decimal.Context.get().rounding`. The
  # `:round_05up` clause IS reached at runtime via the user-supplied
  # rounding-mode string.
  {"lib/pyex/methods.ex", :guard_fail}
]
