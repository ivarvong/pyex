# Source lens: object-aliasing programs — the CROSS PRODUCT {constructor} × {storage} × {mutation},
# each observing a DIFFERENT alias than the one it mutated. This is the class that slips past
# isolation unit tests (every step's return value is correct; the bug is shared identity).
#
# A lens is any module exposing `programs/0 :: [%{id, code, cpython: boolean}]`. `cpython: true` means
# CPython can run it (pure Python, no pyex-only imports) so it's a valid oracle.
defmodule Diff.Lens.Aliasing do
  def programs do
    for kind <- kinds(), build <- kind.builds, {pat, pi} <- Enum.with_index(patterns()) do
      {setup, xexpr, obsexpr} = pat.(build)
      mut = xexpr <> kind.mutate.(7)
      show = String.replace(kind.show, "OBS", obsexpr)
      %{id: "aliasing:#{kind.t}:#{build}:#{pi}", code: "#{setup}\n#{mut}\nprint(#{show})", cpython: true}
    end
  end

  # container kind: constructor forms (literal AND call), its in-place mutation, order-free rendering
  defp kinds,
    do: [
      %{t: "set", builds: ["set()", "set([9])", "{9}"], mutate: fn v -> ".add(#{v})" end, show: "sorted(OBS)"},
      %{t: "list", builds: ["list()", "list([9])", "[9]"], mutate: fn v -> ".append(#{v})" end, show: "OBS"},
      %{t: "dict", builds: ["dict()", "dict([(9, 9)])", "{9: 9}"], mutate: fn v -> "[#{v}] = #{v}" end, show: "sorted(OBS.items())"}
    ]

  # storage pattern: bind container C somewhere aliasable; return {setup, alias-to-mutate, alias-to-observe}
  defp patterns,
    do: [
      fn c -> {"d = {}\nx = d.setdefault('k', #{c})", "x", "d['k']"} end,
      fn c -> {"d = {}\nd['k'] = #{c}\nx = d['k']", "x", "d['k']"} end,
      fn c -> {"L = [#{c}]\nx = L[0]", "x", "L[0]"} end,
      fn c -> {"a = #{c}\nb = a", "b", "a"} end,
      fn c -> {"d = {'k': #{c}}\nx = d['k']", "x", "d['k']"} end,
      fn c -> {"def f(z): return z\nx = f(#{c})", "x", "x"} end
    ]
end
