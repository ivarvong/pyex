defmodule Pyex.CoreBuiltinRegressionTest do
  @moduledoc """
  Regression tests for core builtin/method gaps found by an LLM agent running
  CPython in the pyex sandbox (the PYEX_BUGS.md handoff). Each was reproduced
  differentially against CPython. Every bug gets a positive test (the fix
  behaves like CPython) and a negative test (the failure mode is a clean Python
  exception, never a leaked Elixir crash).

  Expected values were checked against CPython 3.14.
  """

  use ExUnit.Case, async: true

  defp out!(src) do
    {:ok, _v, ctx} = Pyex.run(src)
    String.trim(Pyex.output(ctx))
  end

  describe "max/min/sum iterate a dict's keys" do
    test "positive: max/min/sum over a dict use its keys, like CPython" do
      assert out!("print(max({'a': 1, 'b': 2}))") == "b"
      assert out!("print(min({'a': 1, 'b': 2}))") == "a"
      assert out!("print(sum({1: 9, 2: 9}))") == "3"
      assert out!("d = {'a': 1, 'b': 2}\nprint(max(d, key=lambda k: d[k]))") == "b"
    end

    test "negative: empty dict is ValueError, unsummable keys is TypeError (not a crash)" do
      assert out!("""
             try:
                 max({})
             except ValueError:
                 print("ValueError")
             """) == "ValueError"

      # Summing string keys off the default int start is a TypeError in CPython;
      # pyex used to crash with an Elixir no-clause error here.
      assert out!("""
             try:
                 sum({'a': 1})
             except TypeError:
                 print("TypeError")
             """) == "TypeError"
    end
  end

  describe "sorted/list/reversed keep element references (shallow copy)" do
    test "positive: mutating through a materialized view reaches the original element" do
      assert out!("x = [[1, 2]]\ns = sorted(x)\ns[0][1] = 99\nprint(x)") == "[[1, 99]]"
      assert out!("x = [[1, 2]]\ns = list(x)\ns[0][1] = 99\nprint(x)") == "[[1, 99]]"
      assert out!("x = [[1, 2]]\ns = list(reversed(x))\ns[0][1] = 99\nprint(x)") == "[[1, 99]]"
    end

    test "negative: rebinding the view's slot does not mutate the original list" do
      # Replacing an element of the new list must not touch the source list.
      assert out!("x = [[1, 2]]\ns = list(x)\ns[0] = [7]\nprint(x)") == "[[1, 2]]"
    end
  end

  describe "defaultdict honors default_factory on read (__missing__)" do
    test "positive: a pure read of a missing key creates and stores the default" do
      assert out!("""
             from collections import defaultdict
             d = defaultdict(list)
             d['a'].append(1)
             d['a'].append(2)
             print(dict(d))
             """) == "{'a': [1, 2]}"

      assert out!("""
             from collections import defaultdict
             b = defaultdict(lambda: {'s': set(), 'n': 0})
             b['x']['s'].add('m1')
             print(b['x']['s'])
             """) == "{'m1'}"
    end

    test "negative: a plain dict still raises KeyError on a missing key" do
      assert out!("""
             d = {}
             try:
                 d['x']
             except KeyError:
                 print("KeyError")
             """) == "KeyError"
    end
  end

  describe "Counter.most_common works when built incrementally" do
    test "positive: incremental c[k] += 1 populates most_common" do
      assert out!("""
             from collections import Counter
             c = Counter()
             c['a'] += 1
             c['a'] += 1
             c['b'] += 1
             print(c.most_common())
             """) == "[('a', 2), ('b', 1)]"

      assert out!("""
             from collections import Counter
             c = Counter()
             c['a'] += 1
             c['a'] += 1
             c['b'] += 1
             print(c.most_common(1))
             """) == "[('a', 2)]"
    end

    test "negative: most_common on an empty Counter is []" do
      assert out!("from collections import Counter\nprint(Counter().most_common())") == "[]"
    end
  end

  describe "str.startswith/endswith accept optional start/end" do
    test "positive: 2- and 3-arg forms, tuples, and negative indices" do
      assert out!("print('hello'.startswith('ll', 2))") == "True"
      assert out!("print('hello'.endswith('lo', 0, 5))") == "True"
      assert out!("print('hello'.startswith(('x', 'he')))") == "True"
      assert out!("print('hello'.startswith('lo', -2))") == "True"
      assert out!("print('hello'.endswith('he', 0, 2))") == "True"
    end

    test "negative: a non-match and an out-of-range window return False (no crash)" do
      assert out!("print('hello'.startswith('z', 2))") == "False"
      assert out!("print('hi'.startswith('x', 10))") == "False"
    end
  end

  describe "dir() with no argument lists the current scope" do
    test "positive: module scope shows user names; a function shows its locals exactly" do
      assert out!("x = 1\ny = 2\nprint([n for n in dir() if not n.startswith('_')])") ==
               "['x', 'y']"

      assert out!("""
             def f(a):
                 z = 5
                 return dir()
             print(f(1))
             """) == "['a', 'z']"
    end

    test "negative: builtins are not surfaced (CPython keeps them in a separate namespace)" do
      assert out!("print('print' in dir(), 'len' in dir())") == "False False"
    end
  end

  describe "str.join iterates any iterable of strings" do
    test "positive: joining a str iterates its characters" do
      assert out!("print('#'.join('abc'))") == "a#b#c"
      assert out!("print(''.join('xyz'))") == "xyz"
      assert out!("print('-'.join(['a', 'b', 'c']))") == "a-b-c"
    end

    test "negative: joining a non-iterable is a TypeError (not a leaked crash)" do
      assert out!("""
             try:
                 '-'.join(5)
             except TypeError:
                 print("TypeError")
             """) == "TypeError"
    end
  end
end
