defmodule Pyex.LanguageGapsTest do
  @moduledoc """
  Regression tests for Python language-feature gaps found by a differential
  sweep against CPython 3 (valid Python that pyex parsed wrong, evaluated
  wrong, or crashed on). Each case is pinned to CPython's behaviour.
  """

  use ExUnit.Case, async: true

  defp out!(src) do
    {:ok, _v, ctx} = Pyex.run(src)
    String.trim(Pyex.output(ctx))
  end

  defp file_out!(src) do
    {:ok, _v, ctx} = Pyex.run(src, filesystem: Pyex.FS.new())
    String.trim(Pyex.output(ctx))
  end

  describe "the instance is the first parameter, whatever it's named" do
    test "attribute set via a non-`self` first param persists" do
      assert out!("""
             class C:
                 def __init__(s):
                     s.n = 1
             c = C()
             print(c.n)
             """) == "1"
    end

    test "augmented attribute assignment through a non-`self` param" do
      assert out!("""
             class C:
                 def __init__(this):
                     this.total = 10
                 def add(me, x):
                     me.total += x
             c = C()
             c.add(5)
             print(c.total)
             """) == "15"
    end
  end

  describe "attribute targets in tuple unpacking" do
    test "self.a, self.b = ... inside a method" do
      assert out!("""
             class P:
                 def __init__(self, x, y):
                     self.x, self.y = x, y
             p = P(3, 4)
             print(p.x, p.y)
             """) == "3 4"
    end

    test "mixed name and attribute targets" do
      assert out!("""
             class C:
                 pass
             c = C()
             a, c.b = 1, 2
             print(a, c.b)
             """) == "1 2"
    end

    test "swap through attributes" do
      assert out!("""
             class C:
                 pass
             c = C()
             c.a, c.b = 1, 2
             c.a, c.b = c.b, c.a
             print(c.a, c.b)
             """) == "2 1"
    end

    test "subscript and attribute targets together" do
      assert out!("""
             class C:
                 pass
             c = C()
             d = {}
             c.x, d["k"] = 7, 8
             print(c.x, d["k"])
             """) == "7 8"
    end
  end

  describe "del with multiple targets" do
    test "names" do
      assert out!("""
             a, b, c = 1, 2, 3
             del a, c
             print(b)
             try:
                 print(a)
             except NameError:
                 print("a gone")
             """) == "2\na gone"
    end

    test "subscripts and attributes, with trailing comma" do
      assert out!("""
             class C:
                 pass
             c = C()
             c.x = 1
             d = {"k": 1, "j": 2}
             del c.x, d["k"],
             print(d)
             print(hasattr(c, "x"))
             """) == "{'j': 2}\nFalse"
    end
  end

  describe "matmul operator @" do
    test "unsupported operands raise a clean TypeError (not a host crash)" do
      assert out!("""
             try:
                 print(3 @ 4)
             except TypeError as e:
                 print("TypeError")
             """) == "TypeError"
    end

    test "dispatches to __matmul__ / __rmatmul__" do
      assert out!("""
             class M:
                 def __init__(self, v):
                     self.v = v
                 def __matmul__(self, other):
                     return self.v * other.v
             print(M(3) @ M(4))
             """) == "12"
    end
  end

  describe "NotImplemented singleton and the binop reflection protocol" do
    test "NotImplemented has the right repr, type, and truthiness" do
      assert out!("""
             print(repr(NotImplemented))
             print(type(NotImplemented).__name__)
             print(bool(NotImplemented))
             """) == "NotImplemented\nNotImplementedType\nTrue"
    end

    test "a left dunder returning NotImplemented defers to the right __r-dunder" do
      assert out!("""
             class A:
                 def __add__(self, other):
                     return NotImplemented
             class B:
                 def __radd__(self, other):
                     return "right-handled"
             print(A() + B())
             """) == "right-handled"
    end

    test "both operands declining with NotImplemented raises TypeError" do
      assert out!("""
             class A:
                 def __add__(self, other):
                     return NotImplemented
             class B:
                 def __radd__(self, other):
                     return NotImplemented
             try:
                 A() + B()
             except TypeError:
                 print("TypeError")
             """) == "TypeError"
    end

    test "a builtin left operand falls back to the instance __r-dunder" do
      assert out!("""
             class Money:
                 def __radd__(self, other):
                     return other + 100
             print(5 + Money())
             """) == "105"
    end

    test "__eq__ returning NotImplemented defers to the other operand's __eq__" do
      assert out!("""
             class A:
                 def __eq__(self, other):
                     return NotImplemented
             class B:
                 def __eq__(self, other):
                     return True
             print(A() == B())
             """) == "True"
    end
  end

  describe "file object query and positioning methods" do
    test "readable / writable / seekable reflect the open mode" do
      assert file_out!("""
             f = open("a.txt", "w")
             print(f.writable(), f.readable(), f.seekable())
             f.write("data")
             f.close()
             g = open("a.txt")
             print(g.readable(), g.writable())
             """) == "True False True\nTrue False"
    end

    test "tell reports the write byte count, then the read cursor" do
      assert file_out!("""
             f = open("a.txt", "w")
             f.write("hello")
             print(f.tell())
             f.close()
             g = open("a.txt")
             g.read(2)
             print(g.tell())
             """) == "5\n2"
    end

    test "seek with all three whence modes repositions the read cursor" do
      assert file_out!("""
             f = open("a.txt", "w")
             f.write("abcdef")
             f.close()
             g = open("a.txt")
             g.seek(2)
             print(g.read())
             g.seek(0)
             g.seek(2, 1)
             print(g.read())
             g.seek(-2, 2)
             print(g.read())
             """) == "cdef\ncdef\nef"
    end

    test "writelines concatenates an iterable of strings without separators" do
      assert file_out!("""
             f = open("a.txt", "w")
             f.writelines(["a", "b", "c"])
             f.writelines(("d", "e"))
             f.close()
             print(open("a.txt").read())
             """) == "abcde"
    end

    test "truncate resizes the buffer and flush is a no-op returning None" do
      assert file_out!("""
             f = open("a.txt", "w")
             f.write("abcdef")
             print(f.flush())
             f.truncate(3)
             f.close()
             print(open("a.txt").read())
             """) == "None\nabc"
    end
  end

  describe "file data attributes (name, mode, closed)" do
    test "name and mode echo the open arguments" do
      assert file_out!("""
             f = open("notes.txt", "w")
             print(f.name, f.mode)
             f.write("x")
             f.close()
             g = open("notes.txt")
             print(g.name, g.mode)
             a = open("notes.txt", "a")
             print(a.mode)
             """) == "notes.txt w\nnotes.txt r\na"
    end

    test "closed flips from False to True after close()" do
      assert file_out!("""
             f = open("a.txt", "w")
             print(f.closed)
             f.close()
             print(f.closed)
             """) == "False\nTrue"
    end

    test "dir(file) surfaces the data attributes alongside the methods" do
      assert file_out!("""
             f = open("a.txt", "w")
             names = dir(f)
             print(all(a in names for a in ["closed", "mode", "name"]))
             print(all(m in names for m in ["read", "write", "seek", "tell"]))
             """) == "True\nTrue"
    end
  end

  describe "date / datetime ordinal and ISO-calendar constructors" do
    test "fromordinal inverts toordinal for both date and datetime" do
      assert out!("""
             import datetime as dt
             d = dt.date(2024, 2, 9)
             print(dt.date.fromordinal(d.toordinal()))
             print(dt.datetime.fromordinal(d.toordinal()))
             """) == "2024-02-09\n2024-02-09 00:00:00"
    end

    test "fromisocalendar inverts isocalendar and validates the week" do
      assert out!("""
             import datetime as dt
             d = dt.date(2026, 6, 24)
             y, w, wd = d.isocalendar()
             print(dt.date.fromisocalendar(y, w, wd))
             print(dt.datetime.fromisocalendar(y, w, wd))
             try:
                 dt.date.fromisocalendar(2024, 53, 1)
             except ValueError:
                 print("bad week rejected")
             """) == "2026-06-24\n2026-06-24 00:00:00\nbad week rejected"
    end

    test "date.fromtimestamp returns the UTC calendar date" do
      assert out!("""
             import datetime as dt
             print(dt.date.fromtimestamp(1700000000))
             """) == "2023-11-14"
    end
  end

  describe "str(datetime) uses a space separator, isoformat() uses T" do
    test "print and str render with a space; isoformat keeps the T" do
      assert out!("""
             import datetime as dt
             d = dt.datetime(2024, 3, 15, 10, 30, 45)
             print(d)
             print(str(d))
             print(d.isoformat())
             print(f"{d}")
             """) ==
               "2024-03-15 10:30:45\n2024-03-15 10:30:45\n2024-03-15T10:30:45\n2024-03-15 10:30:45"
    end
  end

  describe "__index__ protocol when indexing a sequence" do
    test "an object with __index__ indexes list, tuple, str, bytes, and range" do
      assert out!("""
             class Idx:
                 def __init__(self, i):
                     self.i = i
                 def __index__(self):
                     return self.i
             print([10, 20, 30][Idx(1)])
             print((10, 20, 30)[Idx(-1)])
             print("abc"[Idx(0)])
             print(b"abc"[Idx(1)])
             print(range(10)[Idx(2)])
             """) == "20\n30\na\n98\n2"
    end

    test "bool is a valid index (True -> 1, False -> 0)" do
      assert out!("""
             print([10, 20][True], [10, 20][False])
             """) == "20 10"
    end

    test "an __index__ returning a non-int raises TypeError" do
      assert out!("""
             class Bad:
                 def __index__(self):
                     return "nope"
             try:
                 [1, 2, 3][Bad()]
             except TypeError:
                 print("TypeError")
             """) == "TypeError"
    end

    test "a dict does not consult __index__ (the instance is a key, not an index)" do
      assert out!("""
             class Key:
                 def __index__(self):
                     return 0
             d = {0: "zero"}
             try:
                 d[Key()]
                 print("coerced")
             except (KeyError, TypeError):
                 print("not coerced")
             """) == "not coerced"
    end

    test "__index__ is consulted by range/hex/oct/bin/chr" do
      assert out!("""
             class I:
                 def __init__(self, n):
                     self.n = n
                 def __index__(self):
                     return self.n
             print(list(range(I(3))))
             print(list(range(I(1), I(5))))
             print(hex(I(255)))
             print(oct(I(8)))
             print(bin(I(5)))
             print(chr(I(65)))
             """) == "[0, 1, 2]\n[1, 2, 3, 4]\n0xff\n0o10\n0b101\nA"
    end

    test "__index__ also coerces slice bounds (start, stop, step)" do
      assert out!("""
             class I:
                 def __init__(self, i):
                     self.i = i
                 def __index__(self):
                     return self.i
             xs = [0, 1, 2, 3, 4, 5]
             print(xs[I(1):I(4)])
             print(xs[I(0):I(6):I(2)])
             print("abcdef"[I(2):])
             print(xs[True:3])
             """) == "[1, 2, 3]\n[0, 2, 4]\ncdef\n[1, 2]"
    end

    test "a slice bound whose __index__ returns a non-int raises TypeError" do
      assert out!("""
             class Bad:
                 def __index__(self):
                     return "x"
             try:
                 [1, 2, 3][Bad():]
             except TypeError:
                 print("TypeError")
             """) == "TypeError"
    end
  end

  describe "sum() over objects uses the __add__ / __radd__ protocol" do
    test "sums instances via __radd__ from the default 0 start" do
      assert out!("""
             class Money:
                 def __init__(self, cents):
                     self.cents = cents
                 def __add__(self, other):
                     other_cents = other.cents if isinstance(other, Money) else other
                     return Money(self.cents + other_cents)
                 def __radd__(self, other):
                     return self.__add__(other)
                 def __repr__(self):
                     return f"Money({self.cents})"
             print(sum([Money(100), Money(250), Money(75)]))
             """) == "Money(425)"
    end

    test "honors an explicit object start without needing __radd__" do
      assert out!("""
             class V:
                 def __init__(self, x):
                     self.x = x
                 def __add__(self, other):
                     return V(self.x + other.x)
                 def __repr__(self):
                     return f"V({self.x})"
             print(sum([V(1), V(2)], V(10)))
             """) == "V(13)"
    end

    test "an object with neither __radd__ nor numeric coercion raises TypeError" do
      assert out!("""
             class V:
                 def __init__(self, x):
                     self.x = x
                 def __add__(self, other):
                     return V(self.x + other.x)
             try:
                 sum([V(1), V(2)])
             except TypeError:
                 print("TypeError")
             """) == "TypeError"
    end
  end

  describe "__format__ protocol via format() and f-strings" do
    test "format() and f-strings dispatch to a custom __format__ with the spec" do
      assert out!("""
             class Temp:
                 def __init__(self, c):
                     self.c = c
                 def __format__(self, spec):
                     return f"{self.c}°{spec or 'C'}"
             t = Temp(20)
             print(format(t, "F"))
             print(f"{t:K}")
             print(f"{t}")
             """) == "20°F\n20°K\n20°C"
    end

    test "an object with no __format__ falls back to str on an empty spec" do
      assert out!("""
             class P:
                 def __str__(self):
                     return "pretty"
             print(format(P()))
             print(f"{P()}")
             """) == "pretty\npretty"
    end

    test "a non-empty spec on an object without __format__ raises TypeError" do
      assert out!("""
             class P:
                 def __str__(self):
                     return "x"
             try:
                 format(P(), ">10")
             except TypeError:
                 print("TypeError")
             """) == "TypeError"
    end

    test "a __format__ returning a non-string raises TypeError" do
      assert out!("""
             class P:
                 def __format__(self, spec):
                     return 42
             try:
                 format(P(), "")
             except TypeError:
                 print("TypeError")
             """) == "TypeError"
    end
  end

  describe "date / datetime class constants (min, max, resolution)" do
    test "date exposes min, max, and resolution" do
      assert out!("""
             import datetime as dt
             print(dt.date.min)
             print(dt.date.max)
             print(dt.date.resolution)
             """) == "0001-01-01\n9999-12-31\n1 day, 0:00:00"
    end

    test "datetime exposes min, max, and resolution" do
      assert out!("""
             import datetime as dt
             print(dt.datetime.min)
             print(dt.datetime.max)
             print(dt.datetime.resolution)
             """) == "0001-01-01 00:00:00\n9999-12-31 23:59:59.999999\n0:00:00.000001"
    end

    test "the constants are also reachable through an instance" do
      assert out!("""
             import datetime as dt
             print(dt.date(2024, 1, 1).max)
             print(type(dt.date.max).__name__)
             """) == "9999-12-31\ndate"
    end
  end

  describe "datetime time-component accessors (time, timetz, tzname, fold)" do
    test "time() and timetz() extract the time component" do
      assert out!("""
             import datetime as dt
             d = dt.datetime(2024, 3, 15, 10, 30, 45, 500)
             print(d.time())
             print(d.timetz())
             t = d.time()
             print(t.hour, t.minute, t.second, t.microsecond)
             print(type(t).__name__)
             """) == "10:30:45.000500\n10:30:45.000500\n10 30 45 500\ntime"
    end

    test "tzname() is None and fold is 0 for a naive datetime" do
      assert out!("""
             import datetime as dt
             d = dt.datetime(2024, 3, 15, 12, 0)
             print(d.tzname())
             print(d.fold)
             """) == "None\n0"
    end

    test "an aware datetime reports its tzname" do
      assert out!("""
             import datetime as dt
             d = dt.datetime(2024, 3, 15, 12, 0, tzinfo=dt.timezone.utc)
             print(d.tzname())
             print(d.time())
             """) == "UTC\n12:00:00"
    end
  end

  describe "struct_time via timetuple / utctimetuple (date + datetime surface complete)" do
    test "timetuple behaves as a tuple: index, unpack, len, iterate, equality" do
      assert out!("""
             import datetime as dt
             tt = dt.date(2024, 3, 15).timetuple()
             print(tt[0], tt[1], tt[2], tt[6], tt[7], tt[8])
             y, mo, d, h, mi, s, wd, yd, isdst = tt
             print(y, mo, d, wd, yd, isdst)
             print(len(tt))
             print(list(tt))
             print(tt == (2024, 3, 15, 0, 0, 0, 4, 75, -1))
             """) ==
               "2024 3 15 4 75 -1\n2024 3 15 4 75 -1\n9\n" <>
                 "[2024, 3, 15, 0, 0, 0, 4, 75, -1]\nTrue"
    end

    test "struct_time exposes named tm_* fields and a CPython repr" do
      assert out!("""
             import datetime as dt
             tt = dt.datetime(2024, 3, 15, 10, 30, 45).timetuple()
             print(tt.tm_year, tt.tm_mon, tt.tm_mday, tt.tm_hour, tt.tm_min, tt.tm_sec)
             print(tt.tm_wday, tt.tm_yday, tt.tm_isdst)
             print(repr(tt))
             """) ==
               "2024 3 15 10 30 45\n4 75 -1\n" <>
                 "time.struct_time(tm_year=2024, tm_mon=3, tm_mday=15, tm_hour=10, " <>
                 "tm_min=30, tm_sec=45, tm_wday=4, tm_yday=75, tm_isdst=-1)"
    end

    test "utctimetuple reports tm_isdst as 0" do
      assert out!("""
             import datetime as dt
             print(dt.datetime(2024, 3, 15, 10, 0).utctimetuple().tm_isdst)
             """) == "0"
    end

    test "date.strptime parses like datetime.strptime and yields a datetime" do
      assert out!("""
             import datetime as dt
             d = dt.date.strptime("2024-01-15", "%Y-%m-%d")
             print(d, type(d).__name__)
             """) == "2024-01-15 00:00:00 datetime"
    end
  end

  describe "dataclass inheritance and frozen=True" do
    test "a subclass dataclass inherits parent fields in order" do
      assert out!("""
             from dataclasses import dataclass
             @dataclass
             class A:
                 x: int
             @dataclass
             class B(A):
                 y: int
             @dataclass
             class C(B):
                 z: int
             c = C(1, 2, 3)
             print(c.x, c.y, c.z)
             """) == "1 2 3"
    end

    test "inherited fields keep their defaults" do
      assert out!("""
             from dataclasses import dataclass
             @dataclass
             class A:
                 x: int = 10
             @dataclass
             class B(A):
                 y: int = 20
             b = B()
             print(b.x, b.y)
             """) == "10 20"
    end

    test "frozen=True blocks assignment with FrozenInstanceError (an AttributeError)" do
      assert out!("""
             from dataclasses import dataclass
             @dataclass(frozen=True)
             class P:
                 x: int
                 y: int
             p = P(1, 2)
             print(p.x, p.y)
             try:
                 p.x = 9
             except Exception as e:
                 print(type(e).__name__)
             try:
                 p.y = 9
             except AttributeError:
                 print("AttributeError")
             """) == "1 2\nFrozenInstanceError\nAttributeError"
    end

    test "a non-frozen dataclass is still mutable" do
      assert out!("""
             from dataclasses import dataclass
             @dataclass
             class P:
                 x: int
             p = P(1)
             p.x = 99
             print(p.x)
             """) == "99"
    end
  end

  describe "functools.partial captures keyword arguments" do
    test "keywords given to partial are merged into the call" do
      assert out!("""
             from functools import partial
             def f(a, b, c):
                 return a + b + c
             g = partial(f, 1, c=10)
             print(g(2))
             h = partial(f, b=5)
             print(h(1, c=3))
             """) == "13\n9"
    end
  end

  describe "enum str/repr and name-based lookup" do
    test "str is Class.NAME and repr is <Class.NAME: value>" do
      assert out!("""
             from enum import Enum
             class Color(Enum):
                 RED = 1
                 GREEN = "g"
             print(str(Color.RED))
             print(repr(Color.RED))
             print(repr(Color.GREEN))
             """) == "Color.RED\n<Color.RED: 1>\n<Color.GREEN: 'g'>"
    end

    test "Class['NAME'] looks up by name, Class(value) by value" do
      assert out!("""
             from enum import Enum
             class Color(Enum):
                 RED = 1
                 GREEN = 2
             print(Color["RED"].value)
             print(Color(2).name)
             try:
                 Color["BLUE"]
             except KeyError:
                 print("KeyError")
             """) == "1\nGREEN\nKeyError"
    end
  end

  describe "__init_subclass__ (PEP 487)" do
    test "a parent's __init_subclass__ runs for each new subclass" do
      assert out!("""
             class Base:
                 def __init_subclass__(cls, **kwargs):
                     print("registering", cls.__name__)
             class A(Base):
                 pass
             class B(A):
                 pass
             """) == "registering A\nregistering B"
    end

    test "__init_subclass__ can set attributes on the new class" do
      assert out!("""
             class Plugin:
                 def __init_subclass__(cls, **kwargs):
                     cls.registered = True
             class MyPlugin(Plugin):
                 pass
             print(MyPlugin.registered)
             """) == "True"
    end

    test "defining the base class itself does not call its hook" do
      assert out!("""
             class Base:
                 def __init_subclass__(cls, **kwargs):
                     print("called for", cls.__name__)
             print("base defined")
             """) == "base defined"
    end

    test "class keyword arguments are threaded to __init_subclass__" do
      assert out!("""
             class Base:
                 def __init_subclass__(cls, label=None, **kwargs):
                     cls.label = label
                     print(sorted(kwargs.items()))
             class Sub(Base, label="hi", a=1, b=2):
                 pass
             print(Sub.label)
             """) == "[('a', 1), ('b', 2)]\nhi"
    end

    test "a metaclass keyword is accepted (class builds normally)" do
      assert out!("""
             from abc import ABCMeta
             class C(metaclass=ABCMeta):
                 x = 1
             print(C().x)
             D = type("D", (), {})
             class E(D, metaclass=type):
                 pass
             print(E.__name__)
             """) == "1\nE"
    end
  end

  describe "data descriptors (__set__) and instance __dict__" do
    test "a data descriptor's __set__ runs on assignment" do
      assert out!("""
             class Positive:
                 def __set__(self, obj, value):
                     if value < 0:
                         raise ValueError("must be >= 0")
                     obj._value = value
                 def __get__(self, obj, owner):
                     return obj._value
             class Account:
                 balance = Positive()
             a = Account()
             a.balance = 100
             print(a.balance)
             try:
                 a.balance = -5
             except ValueError:
                 print("rejected")
             """) == "100\nrejected"
    end

    test "instance __dict__ exposes the attributes as a dict" do
      assert out!("""
             class C:
                 def __init__(self):
                     self.a = 1
                     self.b = 2
             c = C()
             print(c.__dict__)
             print(c.__dict__["a"])
             """) == "{'a': 1, 'b': 2}\n1"
    end
  end

  describe "three-argument type() constructs a class" do
    test "type(name, bases, namespace) builds a usable class" do
      assert out!("""
             T = type("T", (), {"x": 5, "greet": lambda self: "hi"})
             t = T()
             print(t.x, t.greet(), type(t).__name__)
             """) == "5 hi T"
    end

    test "the new class inherits from the given bases" do
      assert out!("""
             class A:
                 def f(self):
                     return "A"
             B = type("B", (A,), {})
             print(B().f(), B.__name__, issubclass(B, A))
             """) == "A B True"
    end

    test "single-argument type() still returns the type" do
      assert out!("""
             print(type(5).__name__, type("x").__name__)
             """) == "int str"
    end

    test "a dynamic class over a builtin base reifies like a class statement" do
      # type('T', (int,), {}) must behave like `class T(int)` — instantiable,
      # isinstance-correct, and never crashing the MRO linearizer.
      assert out!("""
             T = type("T", (int,), {"tag": "x"})
             t = T()
             print(T.tag, isinstance(t, int))
             """) == "x True"
    end
  end

  describe "__class_getitem__ for class subscription" do
    test "a class with __class_getitem__ is subscriptable" do
      assert out!("""
             class Container:
                 def __class_getitem__(cls, item):
                     return f"{cls.__name__}[{item.__name__}]"
             print(Container[int])
             """) == "Container[int]"
    end

    test "classmethod __class_getitem__ works and plain classes raise TypeError" do
      assert out!("""
             class C:
                 @classmethod
                 def __class_getitem__(cls, item):
                     return cls.__name__
             print(C[5])
             class Plain:
                 pass
             try:
                 Plain[int]
             except TypeError:
                 print("TypeError")
             """) == "C\nTypeError"
    end
  end

  describe "memoryview" do
    test "memoryview over bytes supports index, len, slice, iterate" do
      assert out!("""
             mv = memoryview(b"abcdef")
             print(mv[0], mv[-1])
             print(len(mv))
             print(mv[1:4].tobytes())
             print([x for x in memoryview(b"AB")])
             print(type(mv).__name__)
             """) == "97 102\n6\nb'bcd'\n[65, 66]\nmemoryview"
    end

    test "tobytes / hex / tolist, and memoryview over a bytearray" do
      assert out!("""
             mv = memoryview(b"abc")
             print(mv.tobytes())
             print(mv.hex())
             print(mv.tolist())
             print(memoryview(bytearray(b"hi")).tobytes())
             """) == "b'abc'\n616263\n[97, 98, 99]\nb'hi'"
    end
  end

  describe "ExceptionGroup / BaseExceptionGroup" do
    test "ExceptionGroup can be raised and caught, and is an Exception" do
      assert out!("""
             try:
                 raise ExceptionGroup("boom", [ValueError("v"), TypeError("t")])
             except ExceptionGroup:
                 print("caught EG")
             try:
                 raise ExceptionGroup("x", [ValueError()])
             except Exception:
                 print("as Exception")
             """) == "caught EG\nas Exception"
    end

    test "BaseExceptionGroup exists and the names resolve" do
      assert out!("""
             print(ExceptionGroup.__name__)
             print(BaseExceptionGroup.__name__)
             eg = ExceptionGroup("m", [ValueError()])
             print(isinstance(eg, Exception))
             """) == "ExceptionGroup\nBaseExceptionGroup\nTrue"
    end
  end

  describe "globals() and locals()" do
    test "globals() returns the module namespace; builtins are excluded" do
      assert out!("""
             x = 1
             y = 2
             g = globals()
             print(g["x"], g["y"])
             print("__name__" in g)
             print("print" in g)
             """) == "1 2\nTrue\nFalse"
    end

    test "locals() inside a function returns just its locals" do
      assert out!("""
             def f():
                 a = 10
                 b = 20
                 return locals()
             l = f()
             print(sorted(l.keys()), l["a"], l["b"])
             """) == "['a', 'b'] 10 20"
    end

    test "globals() inside a function still sees the module scope" do
      assert out!("""
             z = 99
             def f():
                 return globals()["z"]
             print(f())
             """) == "99"
    end
  end

  describe "super() variants: two-argument and inside classmethods" do
    test "explicit super(Class, self) walks the MRO from Class" do
      assert out!("""
             class A:
                 def f(self):
                     return "A"
             class B(A):
                 def f(self):
                     return "B" + super(B, self).f()
             print(B().f())
             """) == "BA"
    end

    test "zero-arg super() inside a classmethod cooperates up the MRO" do
      assert out!("""
             class A:
                 @classmethod
                 def make(cls):
                     return "A"
             class B(A):
                 @classmethod
                 def make(cls):
                     return "B" + super().make()
             class C(B):
                 @classmethod
                 def make(cls):
                     return "C" + super().make()
             print(C.make())
             """) == "CBA"
    end

    test "explicit super(Class, cls) inside a classmethod" do
      assert out!("""
             class A:
                 @classmethod
                 def tag(cls):
                     return "A"
             class B(A):
                 @classmethod
                 def tag(cls):
                     return "B" + super(B, cls).tag()
             print(B.tag())
             """) == "BA"
    end

    test "super(type, obj) with an unrelated object raises TypeError" do
      assert out!("""
             class A:
                 pass
             class Unrelated:
                 pass
             try:
                 super(A, Unrelated())
             except TypeError:
                 print("TypeError")
             """) == "TypeError"
    end
  end
end
