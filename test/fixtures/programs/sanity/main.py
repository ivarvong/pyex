#!/usr/bin/env python3
"""
Python Interpreter Conformance / Sanity Test
=============================================
Exercises a wide surface of language features and runtime.
Every test prints a deterministic line: "PASS <name>" or "FAIL <name>: <reason>".
Final line: summary counts.

Usage:  python3 main.py
"""

import math, json, re, itertools, collections, csv, datetime

_pass = 0
_fail = 0


def check(name, condition, detail=""):
    global _pass, _fail
    if condition:
        _pass += 1
        print(f"PASS {name}")
    else:
        _fail += 1
        print(f"FAIL {name}: {detail}")


# ── 1. Integer Arithmetic ────────────────────────────────────────────────────
check("int_add", 2 + 3 == 5)
check("int_sub", 10 - 7 == 3)
check("int_mul", 6 * 7 == 42)
check("int_truediv", 7 / 2 == 3.5)
check("int_floordiv", 7 // 2 == 3)
check("int_mod", 7 % 3 == 1)
check("int_pow", 2**10 == 1024)
check("int_neg_floordiv", -7 // 2 == -4)
check("int_neg_mod", -7 % 3 == 2)
check("int_divmod", divmod(17, 5) == (3, 2))
check("int_abs", abs(-42) == 42)
check("int_big_mul", 10**100 * 10**100 == 10**200)
check("int_big_pow", len(str(2**1000)) == 302)
# TODO: needs int.bit_length() method
# check("int_bit_length", (255).bit_length() == 8)
# TODO: needs int.to_bytes() method and bytes type
# check("int_to_bytes", (1024).to_bytes(2, 'big') == b'\x04\x00')
# TODO: needs int.from_bytes() class method and bytes type
# check("int_from_bytes", int.from_bytes(b'\x04\x00', 'big') == 1024)

# ── 2. Float Arithmetic ──────────────────────────────────────────────────────
check("float_add", 0.1 + 0.2 != 0.3)  # IEEE 754 gotcha
check("float_round", round(0.1 + 0.2, 10) == round(0.3, 10))
check("float_inf", float("inf") > 1e308)
check("float_neg_inf", float("-inf") < -1e308)
check("float_nan_ne", float("nan") != float("nan"))
check("float_is_nan", math.isnan(float("nan")))
check("float_is_inf", math.isinf(float("inf")))
# TODO: needs float.fromhex() class method
# check("float_fromhex", float.fromhex('0x1.999999999999ap-4') == 0.1)
# TODO: needs float.as_integer_ratio() method
# check("float_as_integer_ratio", (0.5).as_integer_ratio() == (1, 2))

# ── 3. Complex Numbers ───────────────────────────────────────────────────────
# TODO: needs complex number support
# check("complex_add", (1+2j) + (3+4j) == (4+6j))
# check("complex_mul", (1+2j) * (3+4j) == (-5+10j))
# check("complex_abs", abs(3+4j) == 5.0)
# check("complex_conjugate", (3+4j).conjugate() == (3-4j))
# TODO: needs cmath module
# check("cmath_sqrt", cmath.sqrt(-1) == 1j)
# check("cmath_phase", round(cmath.phase(1j), 10) == round(math.pi/2, 10))

# ── 4. Boolean Logic ─────────────────────────────────────────────────────────
check("bool_and", True and True is True)
check("bool_or", False or True is True)
check("bool_not", not False is True)
check("bool_int", int(True) == 1 and int(False) == 0)
check("bool_is_int_subclass", issubclass(bool, int))
check("bool_arithmetic", True + True == 2)

# ── 5. Bitwise Operations ────────────────────────────────────────────────────
check("bit_and", 0b1100 & 0b1010 == 0b1000)
check("bit_or", 0b1100 | 0b1010 == 0b1110)
check("bit_xor", 0b1100 ^ 0b1010 == 0b0110)
check("bit_not", ~0 == -1)
check("bit_lshift", 1 << 10 == 1024)
check("bit_rshift", 1024 >> 10 == 1)

# ── 6. Strings ────────────────────────────────────────────────────────────────
check("str_concat", "hello" + " " + "world" == "hello world")
check("str_repeat", "ab" * 3 == "ababab")
check("str_index", "abcdef"[2] == "c")
check("str_slice", "abcdef"[1:4] == "bcd")
check("str_step_slice", "abcdef"[::2] == "ace")
check("str_reverse", "abcdef"[::-1] == "fedcba")
check("str_upper", "hello".upper() == "HELLO")
check("str_lower", "HELLO".lower() == "hello")
check("str_strip", "  hi  ".strip() == "hi")
check("str_split", "a,b,c".split(",") == ["a", "b", "c"])
check("str_join", ",".join(["a", "b", "c"]) == "a,b,c")
check("str_replace", "hello".replace("l", "r") == "herro")
check("str_find", "hello".find("ll") == 2)
check("str_startswith", "hello".startswith("hel"))
check("str_endswith", "hello".endswith("llo"))
check("str_isdigit", "12345".isdigit())
check("str_isalpha", "abcXYZ".isalpha())
check("str_count", "banana".count("an") == 2)
check("str_format", "{} {}".format("a", "b") == "a b")
check("str_fstring", f"{1 + 1}" == "2")
check("str_percent", "%s %d" % ("hi", 42) == "hi 42")
# TODO: needs str.encode/decode and bytes type
# check("str_encode_decode", "héllo".encode('utf-8').decode('utf-8') == "héllo")
# TODO: needs str.maketrans/translate
# check("str_maketrans", "abc".translate(str.maketrans("abc", "xyz")) == "xyz")
check("str_zfill", "42".zfill(5) == "00042")
check("str_center", "hi".center(6) == "  hi  ")
check("str_partition", "a=b".partition("=") == ("a", "=", "b"))
check("str_title", "hello world".title() == "Hello World")
# TODO: needs str.casefold()
# check("str_casefold", "Straße".casefold() == "strasse")

# ── 7. Bytes / Bytearray ─────────────────────────────────────────────────────
# TODO: needs bytes/bytearray support
# check("bytes_literal", b'\x00\xff'[1] == 255)
# check("bytes_fromhex", bytes.fromhex('deadbeef') == b'\xde\xad\xbe\xef')
# check("bytearray_mutable", ...)
# check("bytes_decode", b'hello'.decode('ascii') == 'hello')
# check("memoryview_slice", bytes(memoryview(b'abcdef')[1:4]) == b'bcd')

# ── 8. Unicode ────────────────────────────────────────────────────────────────
# TODO: needs correct len() for multi-byte emoji (len counts bytes not codepoints)
# check("unicode_emoji", len("😀") == 1)
# TODO: needs unicodedata module
# check("unicode_name", unicodedata.name('€') == 'EURO SIGN')
# check("unicode_lookup", unicodedata.lookup('SNOWMAN') == '☃')
# check("unicode_category", unicodedata.category('A') == 'Lu')
# check("unicode_normalize", unicodedata.normalize('NFC', '\u00e9') == 'é')

# ── 9. Lists ─────────────────────────────────────────────────────────────────
_la = [1]
_la.append(2)
check("list_append", _la == [1, 2])
check("list_extend", [1] + [2, 3] == [1, 2, 3])
_li = [1, 3]
_li.insert(1, 2)
check("list_insert", _li == [1, 2, 3])
_lp = [1, 2, 3]
check("list_pop", _lp.pop() == 3)
_lr = [1, 2, 3]
_lr.remove(2)
check("list_remove", _lr == [1, 3])
check("list_sort", sorted([3, 1, 2]) == [1, 2, 3])
check("list_sort_key", sorted(["b", "aa", "c"], key=len) == ["b", "c", "aa"])
check("list_sort_reverse", sorted([1, 2, 3], reverse=True) == [3, 2, 1])
check("list_reverse", list(reversed([1, 2, 3])) == [3, 2, 1])
check("list_comprehension", [x**2 for x in range(5)] == [0, 1, 4, 9, 16])
check("list_nested_comp", [x * y for x in [1, 2] for y in [10, 20]] == [10, 20, 20, 40])
check("list_filter_comp", [x for x in range(10) if x % 2 == 0] == [0, 2, 4, 6, 8])
# TODO: needs copy module (deepcopy)
# check("list_copy_independence", ...)
check("list_multiply", [0] * 3 == [0, 0, 0])
check("list_index", [10, 20, 30].index(20) == 1)
check("list_count", [1, 2, 2, 3].count(2) == 2)
_a, *_b, _c = [1, 2, 3, 4, 5]
check("list_star_unpack", _a == 1 and _b == [2, 3, 4] and _c == 5)

# ── 10. Tuples ────────────────────────────────────────────────────────────────
check("tuple_index", (1, 2, 3)[1] == 2)
check("tuple_slice", (1, 2, 3, 4)[1:3] == (2, 3))
check("tuple_concat", (1,) + (2,) == (1, 2))
check("tuple_repeat", (1, 2) * 2 == (1, 2, 1, 2))
_ta, _tb = (10, 20)
check("tuple_unpack_simple", _ta == 10 and _tb == 20)
check("tuple_hash", hash((1, 2, 3)) == hash((1, 2, 3)))
check("tuple_compare", (1, 2) < (1, 3))
check("tuple_single_comma", type((1,)) is tuple)
# TODO: needs collections.namedtuple (not yet implemented)
# check("namedtuple", collections.namedtuple('P', 'x y')(1, 2).y == 2)

# ── 11. Dicts ─────────────────────────────────────────────────────────────────
check("dict_getset", {"a": 1}["a"] == 1)
check("dict_get_default", {}.get("x", 42) == 42)
check("dict_keys", sorted({"b": 2, "a": 1}.keys()) == ["a", "b"])
check("dict_values", sorted({"b": 2, "a": 1}.values()) == [1, 2])
check("dict_items", sorted({"b": 2, "a": 1}.items()) == [("a", 1), ("b", 2)])
_du = {"a": 1}
_du.update({"b": 2})
check("dict_update", _du == {"a": 1, "b": 2})
check("dict_comprehension", {k: v for k, v in [("a", 1), ("b", 2)]} == {"a": 1, "b": 2})
_dp = {"a": 1, "b": 2}
_dp.pop("a")
check("dict_pop", _dp == {"b": 2})
_ds = {}
_ds.setdefault("a", 42)
check("dict_setdefault", _ds == {"a": 42})
check("dict_fromkeys", dict.fromkeys(["a", "b"], 0) == {"a": 0, "b": 0})
# TODO: needs dict | merge operator
# check("dict_merge_310", ({'a':1} | {'b':2}) == {'a':1,'b':2})
check("dict_ordering", list({"a": 1, "b": 2, "c": 3}.keys()) == ["a", "b", "c"])
check("defaultdict", collections.defaultdict(int)["missing"] == 0)
check(
    "ordereddict_eq",
    collections.OrderedDict(a=1, b=2) == collections.OrderedDict(a=1, b=2),
)
check("counter", collections.Counter("abracadabra").most_common(1) == [("a", 5)])
# TODO: needs collections.ChainMap
# check("chainmap", collections.ChainMap({'a':1}, {'a':2, 'b':3})['a'] == 1)

# ── 12. Sets ──────────────────────────────────────────────────────────────────
check("set_create", {1, 2, 3} == {3, 2, 1})
check("set_union", {1, 2} | {2, 3} == {1, 2, 3})
check("set_intersection", {1, 2, 3} & {2, 3, 4} == {2, 3})
check("set_difference", {1, 2, 3} - {2} == {1, 3})
check("set_symmetric_diff", {1, 2, 3} ^ {2, 3, 4} == {1, 4})
check("set_subset", {1, 2}.issubset({1, 2, 3}))
check("set_superset", {1, 2, 3}.issuperset({1, 2}))
check("set_disjoint", {1, 2}.isdisjoint({3, 4}))
check("set_comprehension", {x % 3 for x in range(9)} == {0, 1, 2})
check("frozenset_hash", hash(frozenset([1, 2])) == hash(frozenset([2, 1])))

# ── 13. Control Flow ─────────────────────────────────────────────────────────
_cf = []
for i in range(5):
    if i == 1:
        _cf.append("a")
    elif i == 3:
        _cf.append("b")
    else:
        _cf.append("x")
check("if_elif_else", _cf == ["x", "a", "x", "b", "x"])

_wh = 0
_wi = 10
while _wi > 0:
    _wh += _wi
    _wi -= 1
check("while_loop", _wh == 55)

_br = 0
for i in range(100):
    if i == 5:
        break
    _br += 1
check("break", _br == 5)

_co = []
for i in range(5):
    if i % 2 == 0:
        continue
    _co.append(i)
check("continue", _co == [1, 3])

_fe = []
for i in range(3):
    _fe.append(i)
else:
    _fe.append("done")
check("for_else", _fe == [0, 1, 2, "done"])


# ── 14. Functions ─────────────────────────────────────────────────────────────
def _add(a, b=10):
    return a + b


check("func_default_arg", _add(1) == 11)
check("func_positional", _add(1, 2) == 3)
check("func_keyword", _add(b=5, a=3) == 8)


def _varargs(*args, **kwargs):
    return (args, kwargs)


check("func_varargs", _varargs(1, 2, x=3) == ((1, 2), {"x": 3}))


def _varargs(*args, **kwargs):
    return len(args) + len(kwargs)


check("func_varargs", _varargs(1, 2, x=3) == 3)


def _kwonly(*, x, y=10):
    return x + y


check("func_kwonly", _kwonly(x=5) == 15)

# TODO: needs positional-only parameter syntax (x, y, /)
# def _posonly(x, y, /): return x + y
# check("func_posonly", _posonly(1, 2) == 3)

check("lambda", (lambda x, y: x + y)(3, 4) == 7)


def _make_counter():
    n = 0

    def inc():
        nonlocal n
        n += 1
        return n

    return inc


_ctr = _make_counter()
check("closure_nonlocal", [_ctr(), _ctr(), _ctr()] == [1, 2, 3])


def _fib(n):
    if n <= 1:
        return n
    return _fib(n - 1) + _fib(n - 2)


check("recursion", _fib(10) == 55)


# ── 15. Decorators ────────────────────────────────────────────────────────────
def _double(f):
    def wrapper(*a, **kw):
        return f(*a, **kw) * 2

    return wrapper


@_double
def _compute(x):
    return x + 1


check("decorator_basic", _compute(5) == 12)
# TODO: needs functools.wraps for __name__ preservation
# check("decorator_wraps", _compute.__name__ == "_compute")


def _repeat(n):
    def decorator(f):
        def wrapper(*a, **kw):
            return [f(*a, **kw)] * n

        return wrapper

    return decorator


@_repeat(3)
def _greet():
    return "hi"


check("decorator_with_args", _greet() == ["hi", "hi", "hi"])


# ── 16. Generators ────────────────────────────────────────────────────────────
def _gen_range(n):
    i = 0
    while i < n:
        yield i
        i += 1


check("generator_basic", list(_gen_range(5)) == [0, 1, 2, 3, 4])

# TODO: needs generator.send() method
# def _gen_send():
#     val = yield "start"
#     yield f"got {val}"
# g = _gen_send()
# check("generator_send", next(g) == "start" and g.send("hello") == "got hello")

check("genexpr", sum(x**2 for x in range(5)) == 30)


def _gen_yield_from():
    yield from range(3)
    yield from range(3, 6)


check("yield_from", list(_gen_yield_from()) == [0, 1, 2, 3, 4, 5])

# ── 17. Itertools ─────────────────────────────────────────────────────────────
check("chain", list(itertools.chain([1, 2], [3, 4])) == [1, 2, 3, 4])
check("islice", list(itertools.islice(range(100), 2, 7)) == [2, 3, 4, 5, 6])
check(
    "product",
    list(itertools.product("ab", "12"))
    == [("a", "1"), ("a", "2"), ("b", "1"), ("b", "2")],
)
check("permutations", len(list(itertools.permutations(range(4)))) == 24)
check(
    "combinations",
    list(itertools.combinations([1, 2, 3], 2)) == [(1, 2), (1, 3), (2, 3)],
)
check("accumulate", list(itertools.accumulate([1, 2, 3, 4])) == [1, 3, 6, 10])
# TODO: needs fix for groupby result equality comparison with nested tuples/lists
# check("groupby", [(k, list(v)) for k, v in itertools.groupby("aabbc")] == [('a',['a','a']),('b',['b','b']),('c',['c'])])
check("starmap", list(itertools.starmap(pow, [(2, 3), (3, 2)])) == [8, 9])
check(
    "zip_longest",
    list(itertools.zip_longest([1, 2], [3], fillvalue=0)) == [(1, 3), (2, 0)],
)
check("repeat", list(itertools.repeat(7, 3)) == [7, 7, 7])
check(
    "cycle_islice",
    list(itertools.islice(itertools.cycle([1, 2, 3]), 7)) == [1, 2, 3, 1, 2, 3, 1],
)

# ── 18. Functools ─────────────────────────────────────────────────────────────
# TODO: needs functools module (reduce, partial, lru_cache, total_ordering, cmp_to_key)
# check("reduce", functools.reduce(operator.add, [1,2,3,4]) == 10)
# check("partial", functools.partial(pow, 2)(10) == 1024)
# check("lru_cache", ...)
# check("total_ordering", ...)
# check("cmp_to_key", ...)


# ── 19. Classes ───────────────────────────────────────────────────────────────
class _Animal:
    def __init__(self, name):
        self.name = name

    def speak(self):
        return "..."


class _Dog(_Animal):
    def speak(self):
        return f"{self.name} says woof"


class _Cat(_Animal):
    def speak(self):
        return f"{self.name} says meow"


check("class_inherit", _Dog("Rex").speak() == "Rex says woof")
check("class_isinstance", isinstance(_Dog("x"), _Animal))
check("class_issubclass", issubclass(_Dog, _Animal))


class _Ops:
    def __init__(self, v):
        self.v = v

    def __add__(self, o):
        return _Ops(self.v + o.v)

    def __eq__(self, o):
        return self.v == o.v

    def __repr__(self):
        return f"Ops({self.v})"

    def __hash__(self):
        return hash(self.v)

    def __len__(self):
        return abs(self.v)

    def __bool__(self):
        return self.v != 0

    def __getitem__(self, k):
        return self.v + k

    def __contains__(self, k):
        return k == self.v

    def __iter__(self):
        return iter([self.v])

    def __call__(self, x):
        return self.v * x


check("dunder_add", (_Ops(1) + _Ops(2)) == _Ops(3))
check("dunder_repr", repr(_Ops(5)) == "Ops(5)")
check("dunder_len", len(_Ops(-3)) == 3)
check("dunder_bool", bool(_Ops(0)) is False and bool(_Ops(1)) is True)
check("dunder_getitem", _Ops(10)[5] == 15)
check("dunder_contains", 42 in _Ops(42))
check("dunder_iter", list(_Ops(7)) == [7])
check("dunder_call", _Ops(3)(4) == 12)
check("dunder_hash_set", len({_Ops(1), _Ops(1), _Ops(2)}) == 2)


class _PropClass:
    def __init__(self):
        self._x = 0

    @property
    def x(self):
        return self._x

    @x.setter
    def x(self, v):
        self._x = max(0, v)


_pc = _PropClass()
_pc.x = -5
check("property_getter_setter", _pc.x == 0)

# TODO: needs __slots__ support
# class _SlotClass:
#     __slots__ = ('x', 'y')
# _sc = _SlotClass(); _sc.x = 1; _sc.y = 2
# check("slots", _sc.x == 1 and _sc.y == 2)
# try: _sc.z = 3; check("slots_restrict", False, "allowed new attr")
# except AttributeError: check("slots_restrict", True)


class _StaticClassmethod:
    @staticmethod
    def s():
        return "static"

    @classmethod
    def c(cls):
        return cls.__name__


check("staticmethod", _StaticClassmethod.s() == "static")
check("classmethod", _StaticClassmethod.c() == "_StaticClassmethod")


# MRO / diamond
class _A:
    val = "A"


class _B(_A):
    pass


class _C(_A):
    val = "C"


class _D(_B, _C):
    pass


check("mro_diamond", _D.val == "C")
# TODO: needs __mro__ attribute on classes
# check("mro_order", [c.__name__ for c in _D.__mro__] == ['_D','_B','_C','_A','object'])

# ── 20. Metaclass ─────────────────────────────────────────────────────────────
# TODO: needs metaclass support
# class _Meta(type):
#     def __new__(mcs, name, bases, ns):
#         ns['_meta_mark'] = True
#         return super().__new__(mcs, name, bases, ns)
# class _MetaUser(metaclass=_Meta): pass
# check("metaclass", _MetaUser._meta_mark is True)

# TODO: needs __init_subclass__ support
# class _InitSubBase:
#     _registry = []
#     def __init_subclass__(cls, **kw):
#         super().__init_subclass__(**kw)
#         cls._registry.append(cls.__name__)
# class _ISA(_InitSubBase): pass
# class _ISB(_InitSubBase): pass
# check("init_subclass", _InitSubBase._registry == ['_ISA', '_ISB'])

# ── 21. Abstract Base Classes ─────────────────────────────────────────────────
# TODO: needs abc module
# class _AbsBase(abc.ABC):
#     @abc.abstractmethod
#     def do(self): ...
# try: _AbsBase(); check("abc_instantiate", False, "should raise")
# except TypeError: check("abc_instantiate", True)
# class _AbsConcrete(_AbsBase):
#     def do(self): return 42
# check("abc_concrete", _AbsConcrete().do() == 42)

# ── 22. Dataclasses ──────────────────────────────────────────────────────────
# TODO: needs dataclasses module
# @dataclasses.dataclass(frozen=True)
# class _Point:
#     x: int
#     y: int
# ...

# ── 23. Enums ─────────────────────────────────────────────────────────────────
# TODO: needs enum module
# class _Color(enum.Enum):
#     RED = 1; GREEN = 2; BLUE = 3
# ...

# ── 24. Exceptions ────────────────────────────────────────────────────────────
# TODO: needs raise...from and __cause__/__context__ on exceptions
# def _exc_test():
#     results = []
#     try:
#         try:
#             raise ValueError("inner")
#         except ValueError as e:
#             results.append(str(e))
#             raise TypeError("outer") from e
#     except TypeError as e:
#         results.append(str(e))
#         results.append(str(e.__cause__))
#     return results
# check("exception_chain", _exc_test() == ["inner", "outer", "inner"])


def _exc_else_finally():
    r = []
    try:
        r.append("try")
    except:
        r.append("except")
    else:
        r.append("else")
    finally:
        r.append("finally")
    return r


check("try_else_finally", _exc_else_finally() == ["try", "else", "finally"])


class _CustomExc(Exception):
    def __init__(self, code):
        self.code = code


try:
    raise _CustomExc(404)
except _CustomExc as e:
    check("custom_exception", e.code == 404)

# TODO: needs ExceptionGroup (3.11+ feature) and sys module
# check("exception_group", ...)


# ── 25. Context Managers ──────────────────────────────────────────────────────
class _CM:
    def __init__(self, log):
        self.log = log

    def __enter__(self):
        self.log.append("enter")
        return self

    def __exit__(self, *a):
        self.log.append("exit")
        return False


_cm_log = []
with _CM(_cm_log) as cm:
    _cm_log.append("body")
check("context_manager", _cm_log == ["enter", "body", "exit"])

# TODO: needs contextlib module
# @contextlib.contextmanager
# def _gen_cm():
#     yield 42
# with _gen_cm() as v: pass
# check("contextlib_cm", v == 42)
# with contextlib.suppress(ZeroDivisionError): 1/0
# check("contextlib_suppress", True)

# ── 26. Descriptors ──────────────────────────────────────────────────────────
# TODO: needs descriptor protocol (__set_name__, __get__, __set__)
# class _Validator: ...
# class _Validated: ...
# check("descriptor_get", ...)
# check("descriptor_validate", ...)

# ── 27. Async / Await ────────────────────────────────────────────────────────
# TODO: needs async/await and asyncio module
# async def _async_add(a, b): ...
# check("async_basic", ...)
# check("async_gather", ...)
# check("async_generator", ...)
# check("async_context_manager", ...)

# ── 28. Threading ─────────────────────────────────────────────────────────────
# TODO: needs threading and queue modules
# check("threading_basic", ...)
# check("queue_thread", ...)

# ── 29. Regex ─────────────────────────────────────────────────────────────────
check("re_match", re.match(r"^\d{3}-\d{4}$", "123-4567") is not None)
check("re_search", re.search(r"\b\w+@\w+\.\w+", "email: a@b.com").group() == "a@b.com")
check("re_findall", re.findall(r"\d+", "a1b22c333") == ["1", "22", "333"])
check("re_sub", re.sub(r"\s+", "-", "a  b   c") == "a-b-c")
check("re_split", re.split(r"[,;]", "a,b;c") == ["a", "b", "c"])
check(
    "re_groups", re.match(r"(\w+) (\w+)", "hello world").groups() == ("hello", "world")
)
check("re_named", re.match(r"(?P<first>\w+)", "hello").group("first") == "hello")
check("re_lookahead", re.findall(r"\w+(?=!)", "yes! no. wow!") == ["yes", "wow"])
check("re_compile", re.compile(r"^[a-z]+$").match("abc") is not None)

# ── 30. Math Module ──────────────────────────────────────────────────────────
check("math_sqrt", math.sqrt(144) == 12.0)
check("math_pi", round(math.pi, 5) == 3.14159)
check("math_e", round(math.e, 5) == 2.71828)
check("math_ceil", math.ceil(1.1) == 2)
check("math_floor", math.floor(1.9) == 1)
check("math_log", round(math.log(math.e), 10) == 1.0)
check("math_log2", math.log2(1024) == 10.0)
check("math_factorial", math.factorial(10) == 3628800)
check("math_gcd", math.gcd(48, 18) == 6)
check("math_lcm", math.lcm(4, 6) == 12)
check("math_comb", math.comb(10, 3) == 120)
check("math_perm", math.perm(5, 3) == 60)
check("math_isclose", math.isclose(0.1 + 0.2, 0.3, rel_tol=1e-9))
check("math_prod", math.prod([1, 2, 3, 4, 5]) == 120)
check("math_copysign", math.copysign(1, -3) == -1.0)
check("math_trunc", math.trunc(-3.7) == -3)
# TODO: needs compensated summation in math.fsum
# check("math_fsum", math.fsum([0.1]*10) == 1.0)

# ── 31. Decimal / Fractions ──────────────────────────────────────────────────
# TODO: needs decimal and fractions modules
# check("decimal_precise", str(decimal.Decimal('0.1') + decimal.Decimal('0.2')) == '0.3')
# check("decimal_quantize", ...)
# check("fraction_add", ...)
# check("fraction_from_float", ...)
# check("fraction_limit", ...)

# ── 32. Struct ────────────────────────────────────────────────────────────────
# TODO: needs struct module
# check("struct_pack", ...)
# check("struct_unpack", ...)
# check("struct_calcsize", ...)

# ── 33. Hashlib ───────────────────────────────────────────────────────────────
# TODO: needs hashlib with bytes input support
# check("hashlib_sha256", ...)
# check("hashlib_md5", ...)

# ── 34. JSON ──────────────────────────────────────────────────────────────────
_jdata = {"a": [1, 2.5, True, None, "hello"]}
check("json_roundtrip", json.loads(json.dumps(_jdata)) == _jdata)
check(
    "json_sort_keys", json.dumps({"b": 1, "a": 2}, sort_keys=True) == '{"a": 2, "b": 1}'
)
check("json_indent", "\n" in json.dumps({"a": 1}, indent=2))

# ── 35. Pickle ────────────────────────────────────────────────────────────────
# TODO: needs pickle module
# check("pickle_roundtrip", ...)

# ── 36. Copy ──────────────────────────────────────────────────────────────────
# TODO: needs copy module
# check("copy_shallow", ...)
# check("copy_deep", ...)

# ── 37. Collections ──────────────────────────────────────────────────────────
# TODO: needs collections.deque
# _dq = collections.deque([1,2,3], maxlen=4)
# _dq.appendleft(0); _dq.append(4)
# check("deque_maxlen", list(_dq) == [1, 2, 3, 4])
# _dq2 = collections.deque([1,2,3])
# _dq2.rotate(1)
# check("deque_rotate", list(_dq2) == [3, 1, 2])

# ── 38. Bisect / Heapq ──────────────────────────────────────────────────────
# TODO: needs bisect and heapq modules
# check("bisect_insort", ...)
# check("heapq_pop", ...)
# check("heapq_nlargest", ...)

# ── 39. Array Module ─────────────────────────────────────────────────────────
# TODO: needs array module
# check("array_basic", ...)
# check("array_typecode", ...)

# ── 40. Zip / Enumerate / Map / Filter / Builtins ────────────────────────────
check("zip_basic", list(zip([1, 2], [3, 4])) == [(1, 3), (2, 4)])
check("zip_unequal", list(zip([1, 2], [3])) == [(1, 3)])
check("enumerate_basic", list(enumerate("ab", 1)) == [(1, "a"), (2, "b")])
check("map_basic", list(map(str, [1, 2, 3])) == ["1", "2", "3"])
check("filter_basic", list(filter(None, [0, 1, "", 2])) == [1, 2])
check("any_all", any([0, 1, 0]) and not all([0, 1, 0]))
check("min_max", min(3, 1, 2) == 1 and max(3, 1, 2) == 3)
check("sum_builtin", sum(range(101)) == 5050)
check("sorted_builtin", sorted([3, 1, 2]) == [1, 2, 3])
check("reversed_builtin", list(reversed([1, 2, 3])) == [3, 2, 1])
check("isinstance_multi", isinstance(1, (int, str)))
check("type_check", type(42) is int)
check("callable_check", callable(len) and not callable(42))
check("repr_str", repr("hi") == "'hi'" and str(42) == "42")
check("chr_ord", chr(65) == "A" and ord("A") == 65)
check("hex_oct_bin", hex(255) == "0xff" and oct(8) == "0o10" and bin(5) == "0b101")
check("round_banker", round(2.675, 2) == 2.67)
check("round_builtin", round(1.5) == 2)
check("pow_three_arg", pow(2, 10, 1000) == 24)  # modular exponentiation

# ── 41. Walrus Operator ──────────────────────────────────────────────────────
# TODO: needs walrus operator (:=) support
# _walrus = [y := 10, y + 1, y + 2]
# check("walrus_operator", _walrus == [10, 11, 12] and y == 10)

# ── 42. Match/Case ───────────────────────────────────────────────────────────
# TODO: needs match/case (structural pattern matching)
# check("match_tuple", ...)
# check("match_dict", ...)

# ── 43. Comprehension Scoping ─────────────────────────────────────────────────
x = "outer"
_ = [x for x in range(3)]  # comprehension has own scope in Python 3
check("comprehension_scope", x == "outer")

# ── 44. String IO / Bytes IO ─────────────────────────────────────────────────
# TODO: needs io module (StringIO, BytesIO)
# check("stringio", ...)
# check("bytesio", ...)

# ── 45. Base64 / Binascii / Zlib ─────────────────────────────────────────────
# TODO: needs base64, binascii, zlib modules and bytes type
# check("base64_encode", ...)
# check("zlib_roundtrip", ...)
# check("binascii_hex", ...)

# ── 46. CSV ───────────────────────────────────────────────────────────────────
# NOTE: Pyex has csv module but it uses file handles, not StringIO.
# CSV tests would need filesystem-based approach; skipping for now.
# TODO: needs io.StringIO or file-based csv test
# check("csv_roundtrip", ...)

# ── 47. Datetime ──────────────────────────────────────────────────────────────
_dt = datetime.datetime(2024, 1, 15, 10, 30, 0)
check("datetime_create", _dt.year == 2024 and _dt.month == 1)
check("datetime_strftime", _dt.strftime("%Y-%m-%d") == "2024-01-15")
# TODO: needs datetime.strptime
# check("datetime_parse", datetime.datetime.strptime('2024-01-15', '%Y-%m-%d').day == 15)
# TODO: needs datetime + timedelta addition
# check("timedelta_add", (_dt + datetime.timedelta(days=1)).day == 16)
# TODO: needs timedelta constructor with hours= keyword arg
# check("timedelta_total_seconds", datetime.timedelta(hours=1).total_seconds() == 3600.0)
check("date_iso", datetime.date(2024, 3, 14).isoformat() == "2024-03-14")

# ── 48. Weakref ───────────────────────────────────────────────────────────────
# TODO: needs weakref and gc modules
# check("weakref_alive", ...)
# check("weakref_dead", ...)

# ── 49. GC / Sys ─────────────────────────────────────────────────────────────
# TODO: needs gc and sys modules
# check("gc_collect", ...)
# check("sys_version", ...)
# check("sys_platform", ...)
# check("sys_maxsize", ...)

# ── 50. Inspect ───────────────────────────────────────────────────────────────
# TODO: needs inspect module
# check("inspect_signature", ...)
# check("inspect_isfunction", ...)
# check("inspect_isclass", ...)

# ── 51. Dis (bytecode) ───────────────────────────────────────────────────────
# TODO: needs dis module
# check("dis_bytecode", ...)

# ── 52. Textwrap ──────────────────────────────────────────────────────────────
# TODO: needs textwrap module
# check("textwrap_fill", ...)
# check("textwrap_dedent", ...)
# check("textwrap_indent", ...)

# ── 53. Operator Module ──────────────────────────────────────────────────────
# TODO: needs operator module
# check("operator_add", ...)
# check("operator_itemgetter", ...)

# ── 54. Types Module ─────────────────────────────────────────────────────────
# TODO: needs types module (SimpleNamespace, MappingProxyType, new_class)
# check("simplenamespace", ...)
# check("mappingproxy", ...)
# check("new_class", ...)

# ── 55. Walrus in loops ──────────────────────────────────────────────────────
# TODO: needs walrus operator (:=) support
# _walrus_results = []
# _walrus_data = iter([1, 2, 3, None, 5])
# while (val := next(_walrus_data, None)) is not None:
#     _walrus_results.append(val)
# check("walrus_loop", _walrus_results == [1, 2, 3])

# ── 56. Multiple Assignment / Swap ───────────────────────────────────────────
_ma, _mb = 1, 2
_ma, _mb = _mb, _ma
check("swap", _ma == 2 and _mb == 1)
_mc = _md = _me = 42
check("chained_assign", _mc == 42 and _md == 42 and _me == 42)

# ── 57. Global / Nonlocal ────────────────────────────────────────────────────
_g_val = 0


def _set_global():
    global _g_val
    _g_val = 99


_set_global()
check("global_keyword", _g_val == 99)

# ── 58. Unpacking Generalizations ────────────────────────────────────────────
# TODO: needs **kwargs in lambda params and ** unpacking in call args
# check("dict_unpack_call", (lambda **kw: kw)(**{'a': 1}, **{'b': 2}) == {'a': 1, 'b': 2})
# TODO: needs star-unpack in list/set/dict display literals ([*a, *b], {*a, *b}, {**a, **b})
# check("list_unpack_literal", [*[1,2], *[3,4]] == [1,2,3,4])
# check("set_unpack_literal", {*{1,2}, *{2,3}} == {1,2,3})
# check("dict_unpack_literal", {**{'a':1}, **{'b':2}} == {'a':1,'b':2})

# ── 59. Assignment Expressions in Comprehensions ─────────────────────────────
# TODO: needs walrus operator (:=) support
# _ae = [last := x for x in range(5)]
# check("walrus_in_comp", _ae == [0,1,2,3,4] and last == 4)

# ── 60. F-String Expressions ─────────────────────────────────────────────────
check("fstring_expr", f"{'hello':>10}" == "     hello")
check("fstring_nested", f"result: {f'{1 + 1}'}" == "result: 2")
check("fstring_format_spec", f"{math.pi:.4f}" == "3.1416")
# TODO: needs f-string !r conversion support
# check("fstring_repr", f"{'hi'!r}" == "'hi'")
# TODO: needs f-string = self-documenting expression support
# check("fstring_self_doc", f"{1+1=}" == "1+1=2")

# ── 61. GIL / Memory / Interning ─────────────────────────────────────────────
check("none_singleton", None is None)


# ── 62. Scope and Closures ───────────────────────────────────────────────────
def _make_closures():
    funcs = []
    for i in range(3):

        def _f(x, bound=i):
            return x + bound

        funcs.append(_f)
    return [f(10) for f in funcs]


check("closure_default_capture", _make_closures() == [10, 11, 12])


# TODO: Pyex closures snapshot env at creation time instead of capturing by reference
# def _late_binding():
#     funcs = []
#     for i in range(3):
#         funcs.append(lambda x: x + i)
#     return [f(10) for f in funcs]
# check("closure_late_binding", _late_binding() == [12, 12, 12])

# ── 63. Truthiness ───────────────────────────────────────────────────────────
check("falsy_values", not any([0, 0.0, "", [], (), {}, set(), None, False]))
check("truthy_values", all([1, 0.1, "x", [0], (0,), {0: 0}, {0}]))

# ── 64. Object Identity vs Equality ──────────────────────────────────────────
check("eq_vs_is", [1, 2, 3] == [1, 2, 3] and [1, 2, 3] is not [1, 2, 3])

# ── 65. String Multiplication Edge Cases ─────────────────────────────────────
check("str_mul_zero", "abc" * 0 == "")
check("str_mul_negative", "abc" * -1 == "")

# ── 66. Chained Comparisons ──────────────────────────────────────────────────
check("chained_compare", 1 < 2 < 3 < 4)
check("chained_eq", 1 <= 1 < 2 <= 2)
check("chained_false", not (1 < 2 > 3))

# ── 67. Ternary ──────────────────────────────────────────────────────────────
check("ternary", ("yes" if True else "no") == "yes")


# ── 68. Multiple Inheritance & super() ────────────────────────────────────────
# TODO: needs correct C3 linearization MRO for super() in diamond inheritance
# class _MI_A:
#     def who(self): return ['A']
# class _MI_B(_MI_A):
#     def who(self): return ['B'] + super().who()
# class _MI_C(_MI_A):
#     def who(self): return ['C'] + super().who()
# class _MI_D(_MI_B, _MI_C):
#     def who(self): return ['D'] + super().who()
# check("super_mro", _MI_D().who() == ['D','B','C','A'])


class _Base:
    def who(self):
        return "base"


class _Child(_Base):
    def who(self):
        return "child+" + super().who()


check("super_basic", _Child().who() == "child+base")

# ── 69. __slots__ with inheritance ────────────────────────────────────────────
# TODO: needs __slots__ support
# class _SlotBase:
#     __slots__ = ('x',)
# class _SlotChild(_SlotBase):
#     __slots__ = ('y',)
# _slc = _SlotChild(); _slc.x = 1; _slc.y = 2
# check("slots_inherit", _slc.x == 1 and _slc.y == 2)

# ── 70. Type Hints at Runtime ─────────────────────────────────────────────────
# TODO: needs __annotations__ support
# def _typed(x: int, y: str = "hi") -> bool: return True
# check("type_hints", _typed.__annotations__ == {'x': int, 'y': str, 'return': bool})

# ── 71. Underscore in Numerics ────────────────────────────────────────────────
check("numeric_underscore", 1_000_000 == 1000000 and 0xFF_FF == 65535)

# ── 72. Extended Unpacking in Assignments ─────────────────────────────────────
(a, b), c = [1, 2], 3
check("nested_unpack", a == 1 and b == 2 and c == 3)

# ── 73. __class_getitem__ ────────────────────────────────────────────────────
# TODO: needs __class_getitem__ support
# check("list_type_hint", list[int] == list[int])
# check("dict_type_hint", dict[str, int] == dict[str, int])

# ── 74. Ellipsis ──────────────────────────────────────────────────────────────
# TODO: needs Ellipsis support
# check("ellipsis_singleton", ... is ...)
# check("ellipsis_type", type(...) is type(Ellipsis))

# ── 75. Numeric Tower ────────────────────────────────────────────────────────
check("int_float_eq", 1 == 1.0)
# TODO: needs complex number support
# check("int_complex_eq", 1 == 1+0j)
check("bool_int_eq", True == 1)

# ── 76. Mocking ──────────────────────────────────────────────────────────────
# TODO: needs unittest.mock module
# check("mock_basic", ...)
# check("mock_nested", ...)

# ── 77. String Interning / is vs == ──────────────────────────────────────────
_s1 = "hello_world"
_s2 = "hello" + "_" + "world"
check("string_is_vs_eq", _s1 == _s2)

# ── 78. Big Computation Stress Test ──────────────────────────────────────────
_big_sum = sum(range(1, 1_001))
check("big_sum", _big_sum == 500_500)

# ── 79. List Sorting Stability ────────────────────────────────────────────────
_stable_data = [(1, "b"), (2, "a"), (1, "a"), (2, "b")]
_stable_sorted = sorted(_stable_data, key=lambda x: x[0])
check("sort_stable", _stable_sorted == [(1, "b"), (1, "a"), (2, "a"), (2, "b")])

# ── 80. Dict Ordering (3.7+) ─────────────────────────────────────────────────
_do = {}
_do["c"] = 3
_do["a"] = 1
_do["b"] = 2
check("dict_insert_order", list(_do.keys()) == ["c", "a", "b"])

# ── 81. Complex Comprehension ────────────────────────────────────────────────
_matrix = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
_flat = [x for row in _matrix for x in row]
check("flatten_matrix", _flat == [1, 2, 3, 4, 5, 6, 7, 8, 9])
_transposed = [[row[i] for row in _matrix] for i in range(3)]
check("transpose_matrix", _transposed == [[1, 4, 7], [2, 5, 8], [3, 6, 9]])

# ── 82. Exception Handling Edge Cases ─────────────────────────────────────────
# TODO: needs __context__ on exceptions (implicit chaining)
# def _exc_reraise():
#     try:
#         try: raise ValueError("orig")
#         except ValueError:
#             raise RuntimeError("wrap")
#     except RuntimeError as e:
#         return str(e), type(e.__context__).__name__
# check("exception_implicit_chain", _exc_reraise() == ("wrap", "ValueError"))

# ── 83. Multiline Expressions ────────────────────────────────────────────────
_ml = 1 + 2 + 3
check("multiline_expr", _ml == 6)

# ── 84. Global builtins ──────────────────────────────────────────────────────
# TODO: needs eval/exec builtins
# check("eval_basic", eval("2 + 3") == 5)
# check("exec_basic", ...)
# check("compile_exec", ...)


# ── 85. Object Protocols ─────────────────────────────────────────────────────
class _CtxCounter:
    count = 0

    def __enter__(self):
        _CtxCounter.count += 1
        return self

    def __exit__(self, *a):
        _CtxCounter.count += 1


with _CtxCounter():
    with _CtxCounter():
        pass
check("nested_context", _CtxCounter.count == 4)

# ── 86. Augmented Assignment ──────────────────────────────────────────────────
_aa = 10
_aa += 5
_aa -= 3
_aa *= 2
_aa //= 3
_aa **= 2
_aa %= 7
check("augmented_assign", _aa == 1)  # 10+5=15, -3=12, *2=24, //3=8, **2=64, %7=1

# ── 87. Chained String Methods ────────────────────────────────────────────────
check(
    "chained_str_methods",
    "  Hello, World!  ".strip().lower().replace("!", "").split(", ")
    == ["hello", "world"],
)

# ── 88. Dict Merge Update ────────────────────────────────────────────────────
# TODO: needs dict |= operator
# _dmu = {'a': 1, 'b': 2}; _dmu |= {'b': 3, 'c': 4}
# check("dict_ior", _dmu == {'a': 1, 'b': 3, 'c': 4})

# ── 89. Truthiness Short Circuit ──────────────────────────────────────────────
check("short_circuit_and", (0 and 1 / 0) == 0)  # 1/0 never evaluated
check("short_circuit_or", (1 or 1 / 0) == 1)
check("or_returns_value", (0 or "hello") == "hello")
check("and_returns_value", (1 and "hello") == "hello")

# ── 90. Recursive Data Structures ────────────────────────────────────────────
# TODO: needs recursive repr detection for lists
# _rec = []; _rec.append(_rec)
# check("recursive_list_repr", repr(_rec) == '[[...]]')

# ── 91. Very Large List ──────────────────────────────────────────────────────
_vl = list(range(1_000))
check("large_list_sum", sum(_vl) == 499_500)
check("large_list_len", len(_vl) == 1_000)


# ── 92. Custom Iterator ──────────────────────────────────────────────────────
class _CountDown:
    def __init__(self, n):
        self.n = n

    def __iter__(self):
        return self

    def __next__(self):
        if self.n <= 0:
            raise StopIteration
        self.n -= 1
        return self.n + 1


check("custom_iterator", list(_CountDown(3)) == [3, 2, 1])

# ── 93. Multiple Context Managers ─────────────────────────────────────────────
_mcm = []


class _MCM:
    def __init__(self, n):
        self.n = n

    def __enter__(self):
        _mcm.append(f"e{self.n}")
        return self

    def __exit__(self, *a):
        _mcm.append(f"x{self.n}")


with _MCM(1), _MCM(2), _MCM(3):
    _mcm.append("body")
check("multi_context_manager", _mcm == ["e1", "e2", "e3", "body", "x3", "x2", "x1"])


# ── 94. Dynamic Attribute Access ──────────────────────────────────────────────
class _DynAttr:
    def __getattr__(self, name):
        return f"dynamic_{name}"


check("getattr_dynamic", _DynAttr().anything == "dynamic_anything")
check("hasattr_dynamic", hasattr(_DynAttr(), "xyz"))


# ── 95. __repr__ vs __str__ ──────────────────────────────────────────────────
class _RS:
    def __repr__(self):
        return "RS_repr"

    def __str__(self):
        return "RS_str"


_rs = _RS()
check("str_vs_repr", str(_rs) == "RS_str" and repr(_rs) == "RS_repr")


class _OnlyRepr:
    def __repr__(self):
        return "only_repr"


check("str_falls_back_to_repr", str(_OnlyRepr()) == "only_repr")

# ── 96. Numeric Edge Cases ───────────────────────────────────────────────────
try:
    1 / 0
except ZeroDivisionError:
    check("zero_division", True)
# TODO: needs str(-0.0) == '-0.0'
# check("negative_zero", -0.0 == 0.0 and str(-0.0) == '-0.0')
check("inf_arithmetic", float("inf") + 1 == float("inf"))
check(
    "nan_comparison",
    not (float("nan") < 0) and not (float("nan") > 0) and not (float("nan") == 0),
)

# ── 97. Complex Slice Assignment ──────────────────────────────────────────────
_sl = [0, 1, 2, 3, 4, 5]
_sl[1:4] = [10, 20]
check("slice_assign", _sl == [0, 10, 20, 4, 5])
# TODO: needs del on slices
# _sl2 = [0,1,2,3,4,5]
# del _sl2[::2]
# check("slice_delete", _sl2 == [1, 3, 5])

# ── 98. String Escape Sequences ──────────────────────────────────────────────
check("escape_newline", len("\n") == 1)
check("escape_tab", "\t" == chr(9))
check("escape_null", "\0" == chr(0))
check("escape_unicode", "\u0041" == "A")
check("raw_string", r"\n" == "\\n")

# ── 99. Exec Scoping ─────────────────────────────────────────────────────────
# TODO: needs exec builtin
# _exec_ns = {}
# exec("def f(x): return x * 2", _exec_ns)
# check("exec_scoping", _exec_ns['f'](21) == 42)

# ── 100. Final Summary ──────────────────────────────────────────────────────
print("=" * 60)
print(f"Total: {_pass + _fail} | Pass: {_pass} | Fail: {_fail}")
print("=" * 60)
