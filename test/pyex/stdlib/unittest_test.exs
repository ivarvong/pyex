defmodule Pyex.Stdlib.UnittestTest do
  use ExUnit.Case, async: true

  describe "basic test discovery and execution" do
    test "discovers and runs test methods" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestBasic(unittest.TestCase):
            def test_one(self):
                self.assertEqual(1, 1)

            def test_two(self):
                self.assertTrue(True)

        unittest.main()
        """)

      assert result["total"] == 2
      assert result["passed"] == 2
      assert result["failures"] == 0
      assert result["errors"] == 0
      assert result["success"] == true
      assert output =~ "test_one (TestBasic) ... ok"
      assert output =~ "test_two (TestBasic) ... ok"
      assert output =~ "OK"
    end

    test "runs test methods in alphabetical order" do
      {output, _result} =
        run_with_output("""
        import unittest

        class TestOrder(unittest.TestCase):
            def test_zebra(self):
                self.assertTrue(True)

            def test_alpha(self):
                self.assertTrue(True)

            def test_middle(self):
                self.assertTrue(True)

        unittest.main()
        """)

      lines = String.split(output, "\n")
      test_lines = Enum.filter(lines, &String.contains?(&1, "... ok"))
      assert length(test_lines) == 3
      assert Enum.at(test_lines, 0) =~ "test_alpha"
      assert Enum.at(test_lines, 1) =~ "test_middle"
      assert Enum.at(test_lines, 2) =~ "test_zebra"
    end

    test "only runs methods starting with test" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestFilter(unittest.TestCase):
            def test_real(self):
                self.assertTrue(True)

            def helper(self):
                return 42

            def not_a_test(self):
                self.fail("should not run")

        unittest.main()
        """)

      assert result["total"] == 1
      assert result["passed"] == 1
    end

    test "discovers multiple test classes" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestFirst(unittest.TestCase):
            def test_a(self):
                self.assertTrue(True)

        class TestSecond(unittest.TestCase):
            def test_b(self):
                self.assertTrue(True)

        unittest.main()
        """)

      assert result["total"] == 2
      assert result["passed"] == 2
    end

    test "empty test class with no test methods" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestEmpty(unittest.TestCase):
            def helper(self):
                return 1

        unittest.main()
        """)

      assert result["total"] == 0
      assert result["success"] == true
    end
  end

  describe "from-import style" do
    test "from unittest import TestCase" do
      {_output, result} =
        run_with_output("""
        from unittest import TestCase

        class TestImport(TestCase):
            def test_works(self):
                self.assertEqual(2 + 2, 4)

        import unittest
        unittest.main()
        """)

      assert result["total"] == 1
      assert result["passed"] == 1
    end
  end

  describe "assertEqual" do
    test "passes on equal values" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestEq(unittest.TestCase):
            def test_int(self):
                self.assertEqual(42, 42)

            def test_str(self):
                self.assertEqual("hello", "hello")

            def test_list(self):
                self.assertEqual([1, 2, 3], [1, 2, 3])

        unittest.main()
        """)

      assert result["passed"] == 3
      assert result["failures"] == 0
    end

    test "fails on unequal values" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestEqFail(unittest.TestCase):
            def test_fail(self):
                self.assertEqual(1, 2)

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "FAIL"
      assert output =~ "1 != 2"
    end

    test "uses custom message when provided" do
      {output, _result} =
        run_with_output("""
        import unittest

        class TestEqMsg(unittest.TestCase):
            def test_fail_msg(self):
                self.assertEqual(1, 2, "numbers should match")

        unittest.main()
        """)

      assert output =~ "1 != 2 : numbers should match"
    end
  end

  describe "assertNotEqual" do
    test "passes on different values" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestNe(unittest.TestCase):
            def test_pass(self):
                self.assertNotEqual(1, 2)

        unittest.main()
        """)

      assert result["passed"] == 1
    end

    test "fails on equal values" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestNeFail(unittest.TestCase):
            def test_fail(self):
                self.assertNotEqual(1, 1)

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "1 == 1"
    end
  end

  describe "assertTrue / assertFalse" do
    test "assertTrue passes on truthy values" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestTrue(unittest.TestCase):
            def test_true(self):
                self.assertTrue(True)

            def test_nonzero(self):
                self.assertTrue(1)

            def test_nonempty(self):
                self.assertTrue([1])

        unittest.main()
        """)

      assert result["passed"] == 3
    end

    test "assertTrue fails on falsy values" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestTrueFail(unittest.TestCase):
            def test_false(self):
                self.assertTrue(False)

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "not true"
    end

    test "assertFalse passes on falsy values" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestFalse(unittest.TestCase):
            def test_false(self):
                self.assertFalse(False)

            def test_zero(self):
                self.assertFalse(0)

            def test_empty(self):
                self.assertFalse([])

        unittest.main()
        """)

      assert result["passed"] == 3
    end

    test "assertFalse fails on truthy values" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestFalseFail(unittest.TestCase):
            def test_true(self):
                self.assertFalse(True)

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "not false"
    end
  end

  describe "assertIs / assertIsNot" do
    test "assertIs passes on identical values" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestIs(unittest.TestCase):
            def test_none(self):
                self.assertIs(None, None)

            def test_bool(self):
                self.assertIs(True, True)

        unittest.main()
        """)

      assert result["passed"] == 2
    end

    test "assertIsNot passes on non-identical values" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestIsNot(unittest.TestCase):
            def test_pass(self):
                self.assertIsNot(1, 2)

        unittest.main()
        """)

      assert result["passed"] == 1
    end
  end

  describe "assertIsNone / assertIsNotNone" do
    test "assertIsNone passes on None" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestNone(unittest.TestCase):
            def test_pass(self):
                self.assertIsNone(None)

        unittest.main()
        """)

      assert result["passed"] == 1
    end

    test "assertIsNone fails on non-None" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestNoneFail(unittest.TestCase):
            def test_fail(self):
                self.assertIsNone(42)

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "is not None"
    end

    test "assertIsNotNone passes on non-None" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestNotNone(unittest.TestCase):
            def test_pass(self):
                self.assertIsNotNone(42)

        unittest.main()
        """)

      assert result["passed"] == 1
    end

    test "assertIsNotNone fails on None" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestNotNoneFail(unittest.TestCase):
            def test_fail(self):
                self.assertIsNotNone(None)

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "unexpectedly None"
    end
  end

  describe "assertIn / assertNotIn" do
    test "assertIn passes when item is in container" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestIn(unittest.TestCase):
            def test_list(self):
                self.assertIn(2, [1, 2, 3])

            def test_string(self):
                self.assertIn("ell", "hello")

            def test_dict(self):
                self.assertIn("a", {"a": 1})

        unittest.main()
        """)

      assert result["passed"] == 3
    end

    test "assertIn fails when item is not in container" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestInFail(unittest.TestCase):
            def test_fail(self):
                self.assertIn(5, [1, 2, 3])

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "not found in"
    end

    test "assertNotIn passes when item is absent" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestNotIn(unittest.TestCase):
            def test_pass(self):
                self.assertNotIn(5, [1, 2, 3])

        unittest.main()
        """)

      assert result["passed"] == 1
    end

    test "assertNotIn fails when item is present" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestNotInFail(unittest.TestCase):
            def test_fail(self):
                self.assertNotIn(2, [1, 2, 3])

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "unexpectedly found in"
    end
  end

  describe "comparison assertions" do
    test "assertGreater passes" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestGt(unittest.TestCase):
            def test_pass(self):
                self.assertGreater(5, 3)

        unittest.main()
        """)

      assert result["passed"] == 1
    end

    test "assertGreater fails" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestGtFail(unittest.TestCase):
            def test_fail(self):
                self.assertGreater(3, 5)

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "not greater than"
    end

    test "assertGreaterEqual passes on equal" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestGe(unittest.TestCase):
            def test_pass(self):
                self.assertGreaterEqual(5, 5)

        unittest.main()
        """)

      assert result["passed"] == 1
    end

    test "assertLess passes" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestLt(unittest.TestCase):
            def test_pass(self):
                self.assertLess(3, 5)

        unittest.main()
        """)

      assert result["passed"] == 1
    end

    test "assertLessEqual passes on equal" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestLe(unittest.TestCase):
            def test_pass(self):
                self.assertLessEqual(5, 5)

        unittest.main()
        """)

      assert result["passed"] == 1
    end
  end

  describe "assertAlmostEqual" do
    test "passes for close floats" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestAlmost(unittest.TestCase):
            def test_close(self):
                self.assertAlmostEqual(0.1 + 0.2, 0.3)

        unittest.main()
        """)

      assert result["passed"] == 1
    end

    test "fails for distant floats" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestAlmostFail(unittest.TestCase):
            def test_far(self):
                self.assertAlmostEqual(1.0, 2.0)

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "within 7 places"
    end

    test "custom places parameter" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestAlmostPlaces(unittest.TestCase):
            def test_1_place(self):
                self.assertAlmostEqual(1.01, 1.02, 1)

        unittest.main()
        """)

      assert result["passed"] == 1
    end
  end

  describe "assertIsInstance" do
    test "passes for correct instance" do
      {_output, result} =
        run_with_output("""
        import unittest

        class Animal:
            pass

        class Dog(Animal):
            pass

        class TestInstance(unittest.TestCase):
            def test_direct(self):
                d = Dog()
                self.assertIsInstance(d, Dog)

            def test_base(self):
                d = Dog()
                self.assertIsInstance(d, Animal)

        unittest.main()
        """)

      assert result["passed"] == 2
    end

    test "fails for wrong instance" do
      {output, result} =
        run_with_output("""
        import unittest

        class Cat:
            pass

        class Dog:
            pass

        class TestInstanceFail(unittest.TestCase):
            def test_fail(self):
                d = Dog()
                self.assertIsInstance(d, Cat)

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "not an instance of"
    end
  end

  describe "fail" do
    test "explicit fail" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestFail(unittest.TestCase):
            def test_explicit(self):
                self.fail("should not reach")

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "should not reach"
    end

    test "fail without message" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestFailNoMsg(unittest.TestCase):
            def test_fail(self):
                self.fail()

        unittest.main()
        """)

      assert result["failures"] == 1
      assert output =~ "explicitly failed"
    end
  end

  describe "setUp and tearDown" do
    test "setUp runs before each test" do
      {output, _result} =
        run_with_output("""
        import unittest

        class TestSetup(unittest.TestCase):
            def setUp(self):
                self.value = 10

            def test_uses_setup(self):
                self.assertEqual(self.value, 10)

        unittest.main()
        """)

      assert output =~ "test_uses_setup (TestSetup) ... ok"
    end

    test "tearDown runs after each test" do
      {output, _result} =
        run_with_output("""
        import unittest

        class TestTeardown(unittest.TestCase):
            def setUp(self):
                self.items = []

            def test_something(self):
                self.items.append(1)
                self.assertEqual(len(self.items), 1)

            def tearDown(self):
                print("teardown ran")

        unittest.main()
        """)

      assert output =~ "teardown ran"
      assert output =~ "test_something (TestTeardown) ... ok"
    end
  end

  describe "failure and error distinction" do
    test "assertion failure vs runtime error" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestDistinction(unittest.TestCase):
            def test_assertion_fail(self):
                self.assertEqual(1, 2)

            def test_runtime_error(self):
                x = 1 / 0

        unittest.main()
        """)

      assert result["failures"] == 1
      assert result["errors"] == 1
      assert result["total"] == 2
      assert output =~ "FAIL"
      assert output =~ "ERROR"
      assert output =~ "FAILED"
    end

    test "mixed passing and failing" do
      {output, result} =
        run_with_output("""
        import unittest

        class TestMixed(unittest.TestCase):
            def test_a_pass(self):
                self.assertTrue(True)

            def test_b_fail(self):
                self.assertEqual(1, 2)

            def test_c_pass(self):
                self.assertIn(1, [1, 2])

        unittest.main()
        """)

      assert result["total"] == 3
      assert result["passed"] == 2
      assert result["failures"] == 1
      assert output =~ "test_a_pass (TestMixed) ... ok"
      assert output =~ "test_b_fail (TestMixed) ... FAIL"
      assert output =~ "test_c_pass (TestMixed) ... ok"
    end
  end

  describe "return value structure" do
    test "returns dict with correct keys" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestSummary(unittest.TestCase):
            def test_one(self):
                self.assertTrue(True)

        unittest.main()
        """)

      assert is_map(result)
      assert Map.has_key?(result, "total")
      assert Map.has_key?(result, "passed")
      assert Map.has_key?(result, "failures")
      assert Map.has_key?(result, "errors")
      assert Map.has_key?(result, "success")
    end

    test "success is true when all pass" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestSuccess(unittest.TestCase):
            def test_pass(self):
                self.assertTrue(True)

        unittest.main()
        """)

      assert result["success"] == true
    end

    test "success is false when any fail" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestFail(unittest.TestCase):
            def test_fail(self):
                self.assertEqual(1, 2)

        unittest.main()
        """)

      assert result["success"] == false
    end
  end

  describe "output format" do
    test "prints separator and summary" do
      {output, _result} =
        run_with_output("""
        import unittest

        class TestOutput(unittest.TestCase):
            def test_one(self):
                self.assertTrue(True)

        unittest.main()
        """)

      assert output =~ "----------------------------------------------------------------------"
      assert output =~ "Ran 1 test"
      assert output =~ "OK"
    end

    test "pluralizes tests correctly" do
      {output, _result} =
        run_with_output("""
        import unittest

        class TestPlural(unittest.TestCase):
            def test_a(self):
                self.assertTrue(True)

            def test_b(self):
                self.assertTrue(True)

        unittest.main()
        """)

      assert output =~ "Ran 2 tests"
    end

    test "shows failure count in FAILED message" do
      {output, _result} =
        run_with_output("""
        import unittest

        class TestFailMsg(unittest.TestCase):
            def test_a(self):
                self.assertEqual(1, 2)

            def test_b(self):
                self.assertEqual(3, 4)

        unittest.main()
        """)

      assert output =~ "FAILED (failures=2)"
    end
  end

  describe "assertIn with tuples and sets" do
    test "assertIn with tuple" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestTuple(unittest.TestCase):
            def test_in_tuple(self):
                self.assertIn(2, (1, 2, 3))

        unittest.main()
        """)

      assert result["passed"] == 1
    end

    test "assertIn with set" do
      {_output, result} =
        run_with_output("""
        import unittest

        class TestSet(unittest.TestCase):
            def test_in_set(self):
                self.assertIn(2, {1, 2, 3})

        unittest.main()
        """)

      assert result["passed"] == 1
    end
  end

  describe "realistic test scenarios" do
    test "testing a calculator class" do
      {_output, result} =
        run_with_output("""
        import unittest

        class Calculator:
            def add(self, a, b):
                return a + b

            def multiply(self, a, b):
                return a * b

        class TestCalculator(unittest.TestCase):
            def setUp(self):
                self.calc = Calculator()

            def test_add(self):
                self.assertEqual(self.calc.add(2, 3), 5)

            def test_add_negative(self):
                self.assertEqual(self.calc.add(-1, 1), 0)

            def test_multiply(self):
                self.assertEqual(self.calc.multiply(3, 4), 12)

            def test_multiply_zero(self):
                self.assertEqual(self.calc.multiply(5, 0), 0)

        unittest.main()
        """)

      assert result["total"] == 4
      assert result["passed"] == 4
      assert result["success"] == true
    end

    test "testing a stack implementation" do
      {_output, result} =
        run_with_output("""
        import unittest

        class Stack:
            def __init__(self):
                self.items = []

            def push(self, item):
                self.items.append(item)

            def pop(self):
                return self.items.pop()

            def peek(self):
                return self.items[-1]

            def is_empty(self):
                return len(self.items) == 0

            def size(self):
                return len(self.items)

        class TestStack(unittest.TestCase):
            def setUp(self):
                self.stack = Stack()

            def test_empty_on_creation(self):
                self.assertTrue(self.stack.is_empty())

            def test_push_and_peek(self):
                self.stack.push(42)
                self.assertEqual(self.stack.peek(), 42)

            def test_push_and_pop(self):
                self.stack.push(1)
                self.stack.push(2)
                self.assertEqual(self.stack.pop(), 2)
                self.assertEqual(self.stack.pop(), 1)

            def test_size(self):
                self.stack.push("a")
                self.stack.push("b")
                self.assertEqual(self.stack.size(), 2)

        unittest.main()
        """)

      assert result["total"] == 4
      assert result["passed"] == 4
      assert result["success"] == true
    end
  end

  defp run_with_output(code) do
    {:ok, result, ctx} = Pyex.run(code)
    {Pyex.output(ctx), result}
  end
end
