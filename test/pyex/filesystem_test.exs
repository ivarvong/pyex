defmodule Pyex.FilesystemTest do
  use ExUnit.Case, async: true

  alias Pyex.{Builtins, Ctx, Interpreter, Lexer, Parser}
  alias Pyex.Filesystem.Memory

  defp parse!(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)
    ast
  end

  defp run_with_fs!(source, fs \\ Memory.new()) do
    ast = parse!(source)
    ctx = Ctx.new(filesystem: fs)

    case Interpreter.run_with_ctx(ast, Builtins.env(), ctx) do
      {:ok, value, _env, ctx} ->
        {value, close_handles(ctx)}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp close_handles(ctx) do
    Enum.reduce(Map.keys(ctx.handles), ctx, fn id, ctx ->
      case Ctx.close_handle(ctx, id) do
        {:ok, ctx} -> ctx
        {:error, _} -> ctx
      end
    end)
  end

  defp run_with_fs_public!(source, fs \\ Memory.new()) do
    case Pyex.run(source, filesystem: fs) do
      {:ok, value, ctx} -> {value, ctx}
      {:error, error} -> {:error, error.message}
    end
  end

  describe "Filesystem.Memory" do
    test "read from pre-populated file" do
      fs = Memory.new(%{"hello.txt" => "hello world"})
      assert {:ok, "hello world"} = Memory.read(fs, "hello.txt")
    end

    test "read missing file returns error" do
      fs = Memory.new()
      assert {:error, "FileNotFoundError:" <> _} = Memory.read(fs, "nope.txt")
    end

    test "write creates file" do
      fs = Memory.new()
      {:ok, fs} = Memory.write(fs, "test.txt", "content", :write)
      assert {:ok, "content"} = Memory.read(fs, "test.txt")
    end

    test "write mode truncates" do
      fs = Memory.new(%{"test.txt" => "old"})
      {:ok, fs} = Memory.write(fs, "test.txt", "new", :write)
      assert {:ok, "new"} = Memory.read(fs, "test.txt")
    end

    test "append mode appends" do
      fs = Memory.new(%{"test.txt" => "first"})
      {:ok, fs} = Memory.write(fs, "test.txt", " second", :append)
      assert {:ok, "first second"} = Memory.read(fs, "test.txt")
    end

    test "exists? returns true for existing file" do
      fs = Memory.new(%{"a.txt" => ""})
      assert Memory.exists?(fs, "a.txt")
    end

    test "exists? returns false for missing file" do
      fs = Memory.new()
      refute Memory.exists?(fs, "a.txt")
    end

    test "exists? returns true for implicit directory" do
      fs = Memory.new(%{"dir/file.txt" => ""})
      assert Memory.exists?(fs, "dir")
    end

    test "list_dir returns entries" do
      fs = Memory.new(%{"a.txt" => "", "b.txt" => "", "dir/c.txt" => ""})
      assert {:ok, entries} = Memory.list_dir(fs, "")
      assert "a.txt" in entries
      assert "b.txt" in entries
      assert "dir" in entries
    end

    test "delete removes file" do
      fs = Memory.new(%{"a.txt" => "content"})
      {:ok, fs} = Memory.delete(fs, "a.txt")
      refute Memory.exists?(fs, "a.txt")
    end

    test "delete missing file returns error" do
      fs = Memory.new()
      assert {:error, "FileNotFoundError:" <> _} = Memory.delete(fs, "nope.txt")
    end

    test "path normalization strips leading/trailing slashes" do
      fs = Memory.new(%{"dir/file.txt" => "content"})
      assert {:ok, "content"} = Memory.read(fs, "/dir/file.txt")
    end
  end

  describe "Python file I/O with Memory backend" do
    test "open and read a file" do
      fs = Memory.new(%{"data.txt" => "hello from file"})

      code = """
      f = open("data.txt", "r")
      content = f.read()
      f.close()
      content
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == "hello from file"
    end

    test "open with default read mode" do
      fs = Memory.new(%{"data.txt" => "default read"})

      code = """
      f = open("data.txt")
      content = f.read()
      f.close()
      content
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == "default read"
    end

    test "write to a file" do
      code = """
      f = open("output.txt", "w")
      f.write("line 1")
      f.write("line 2")
      f.close()
      g = open("output.txt", "r")
      result = g.read()
      g.close()
      result
      """

      {value, _ctx} = run_with_fs!(code)
      assert value == "line 1line 2"
    end

    test "append to a file" do
      fs = Memory.new(%{"log.txt" => "existing "})

      code = """
      f = open("log.txt", "a")
      f.write("appended")
      f.close()
      g = open("log.txt", "r")
      result = g.read()
      g.close()
      result
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == "existing appended"
    end

    test "reading missing file returns error" do
      code = """
      f = open("nope.txt", "r")
      """

      assert {:error, msg} = run_with_fs!(code)
      assert msg =~ "FileNotFoundError"
    end

    test "writing without close persists to filesystem on program exit" do
      code = """
      f = open("test.txt", "w")
      f.write("not explicitly closed")
      """

      {_value, ctx} = run_with_fs!(code)

      assert {:ok, "not explicitly closed"} =
               Pyex.Filesystem.Memory.read(ctx.filesystem, "test.txt")
    end

    test "one-liner open().write() persists to filesystem" do
      code = ~S|open("out.txt", "w").write("hello")|

      {_value, ctx} = run_with_fs!(code)
      assert {:ok, "hello"} = Pyex.Filesystem.Memory.read(ctx.filesystem, "out.txt")
    end

    test "unclosed append handle flushes on program exit" do
      fs = Pyex.Filesystem.Memory.new(%{"log.txt" => "line1,"})

      code = """
      f = open("log.txt", "a")
      f.write("line2")
      """

      {_value, ctx} = run_with_fs!(code, fs)
      assert {:ok, "line1,line2"} = Pyex.Filesystem.Memory.read(ctx.filesystem, "log.txt")
    end

    test "multiple unclosed handles all flush on program exit" do
      code = """
      a = open("a.txt", "w")
      b = open("b.txt", "w")
      a.write("aaa")
      b.write("bbb")
      """

      {_value, ctx} = run_with_fs!(code)
      assert {:ok, "aaa"} = Pyex.Filesystem.Memory.read(ctx.filesystem, "a.txt")
      assert {:ok, "bbb"} = Pyex.Filesystem.Memory.read(ctx.filesystem, "b.txt")
    end

    test "no open handles remain in ctx after program exit" do
      code = """
      f = open("test.txt", "w")
      f.write("data")
      """

      {_value, ctx} = run_with_fs!(code)
      assert ctx.handles == %{}
    end

    test "Pyex.run flushes unclosed handles on program exit" do
      code = ~S|open("out.txt", "w").write("hello")|

      assert {:ok, _, ctx} = Pyex.run(code, filesystem: Memory.new())
      assert {:ok, "hello"} = Pyex.Filesystem.Memory.read(ctx.filesystem, "out.txt")
      assert ctx.handles == %{}
    end

    test "Pyex.run flushes unclosed append handles on program exit" do
      fs = Memory.new(%{"log.txt" => "line1,"})

      code = """
      f = open("log.txt", "a")
      f.write("line2")
      """

      {_value, ctx} = run_with_fs_public!(code, fs)
      assert {:ok, "line1,line2"} = Pyex.Filesystem.Memory.read(ctx.filesystem, "log.txt")
      assert ctx.handles == %{}
    end

    test "Pyex.run flushes multiple unclosed handles on program exit" do
      code = """
      a = open("a.txt", "w")
      b = open("b.txt", "w")
      a.write("aaa")
      b.write("bbb")
      """

      {_value, ctx} = run_with_fs_public!(code)
      assert {:ok, "aaa"} = Pyex.Filesystem.Memory.read(ctx.filesystem, "a.txt")
      assert {:ok, "bbb"} = Pyex.Filesystem.Memory.read(ctx.filesystem, "b.txt")
      assert ctx.handles == %{}
    end

    test "Pyex.run clears unclosed read handles on program exit" do
      fs = Memory.new(%{"in.txt" => "data"})

      code = """
      f = open("in.txt", "r")
      f.read()
      """

      {_value, ctx} = run_with_fs_public!(code, fs)
      assert {:ok, "data"} = Pyex.Filesystem.Memory.read(ctx.filesystem, "in.txt")
      assert ctx.handles == %{}
    end

    test "error results preserve ctx so unclosed writes can be flushed purely" do
      code = """
      f = open("boom.txt", "w")
      f.write("before error")
      raise ValueError("boom")
      """

      ast = parse!(code)
      ctx = Ctx.new(filesystem: Memory.new())

      assert {:error, msg, final_ctx} = Interpreter.run_with_ctx_result(ast, Builtins.env(), ctx)
      assert msg =~ "ValueError"

      final_ctx = close_handles(final_ctx)
      assert {:ok, "before error"} = Pyex.Filesystem.Memory.read(final_ctx.filesystem, "boom.txt")
      assert final_ctx.handles == %{}
    end

    test "multiple file handles simultaneously" do
      fs = Memory.new(%{"a.txt" => "aaa", "b.txt" => "bbb"})

      code = """
      f1 = open("a.txt", "r")
      f2 = open("b.txt", "r")
      a = f1.read()
      b = f2.read()
      f1.close()
      f2.close()
      a + b
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == "aaabbb"
    end

    test "file operations are logged in ctx" do
      fs = Memory.new(%{"data.txt" => "test"})

      code = """
      f = open("data.txt", "r")
      content = f.read()
      f.close()
      content
      """

      {_value, ctx} = run_with_fs!(code, fs)

      # File operations are tracked via counters, not event log
      assert ctx.file_ops >= 3
    end

    test "no filesystem configured returns error" do
      ast = parse!(~s[f = open("test.txt", "r")])
      ctx = Ctx.new()

      assert {:error, msg} = Interpreter.run_with_ctx(ast, Builtins.env(), ctx)
      assert msg =~ "no filesystem"
    end
  end

  describe "with open() context manager" do
    test "with open() for writing flushes on block exit" do
      code = """
      with open("output.csv", "w") as f:
          f.write("hello")
      g = open("output.csv", "r")
      result = g.read()
      g.close()
      result
      """

      {value, _ctx} = run_with_fs!(code)
      assert value == "hello"
    end

    test "with open() for reading" do
      fs = Memory.new(%{"data.txt" => "file content"})

      code = """
      with open("data.txt", "r") as f:
          result = f.read()
      result
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == "file content"
    end

    test "with open() closes handle on normal exit" do
      code = """
      with open("test.txt", "w") as f:
          f.write("data")
      """

      {_value, ctx} = run_with_fs!(code)
      assert ctx.handles == %{}
    end

    test "with open() closes handle on exception" do
      code = """
      try:
          with open("test.txt", "w") as f:
              f.write("data")
              raise ValueError("oops")
      except ValueError:
          pass
      """

      {_value, ctx} = run_with_fs!(code)
      assert ctx.handles == %{}
    end

    test "with open() flushes buffer on exception" do
      code = """
      try:
          with open("test.txt", "w") as f:
              f.write("written before error")
              raise ValueError("oops")
      except ValueError:
          pass
      g = open("test.txt", "r")
      result = g.read()
      g.close()
      result
      """

      {value, _ctx} = run_with_fs!(code)
      assert value == "written before error"
    end

    test "with open() for append mode" do
      fs = Memory.new(%{"log.txt" => "line1,"})

      code = """
      with open("log.txt", "a") as f:
          f.write("line2")
      g = open("log.txt", "r")
      result = g.read()
      g.close()
      result
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == "line1,line2"
    end

    test "with open() multiple writes accumulate" do
      code = """
      with open("out.txt", "w") as f:
          f.write("a")
          f.write("b")
          f.write("c")
      g = open("out.txt", "r")
      result = g.read()
      g.close()
      result
      """

      {value, _ctx} = run_with_fs!(code)
      assert value == "abc"
    end

    test "nested with open() statements" do
      fs = Memory.new(%{"input.txt" => "source data"})

      code = """
      with open("input.txt", "r") as src:
          data = src.read()
      with open("output.txt", "w") as dst:
          dst.write(data)
      g = open("output.txt", "r")
      result = g.read()
      g.close()
      result
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == "source data"
    end

    test "with open() without as clause" do
      code = """
      with open("test.txt", "w"):
          pass
      """

      {_value, ctx} = run_with_fs!(code)
      assert ctx.handles == %{}
    end

    test "with open() file is usable inside block" do
      fs = Memory.new(%{"nums.txt" => "12345"})

      code = """
      with open("nums.txt", "r") as f:
          content = f.read()
          length = len(content)
      (content, length)
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == {:tuple, ["12345", 5]}
    end

    test "variable assigned inside with block persists after" do
      fs = Memory.new(%{"data.txt" => "hello"})

      code = """
      with open("data.txt", "r") as f:
          captured = f.read()
      captured
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == "hello"
    end

    test "with open() write then read in sequence" do
      code = """
      with open("file.txt", "w") as f:
          f.write("round trip")
      with open("file.txt", "r") as f:
          result = f.read()
      result
      """

      {value, _ctx} = run_with_fs!(code)
      assert value == "round trip"
    end

    test "with open() exception does not suppress by default" do
      code = """
      result = "no error"
      try:
          with open("test.txt", "w") as f:
              raise TypeError("boom")
      except TypeError:
          result = "caught"
      result
      """

      {value, _ctx} = run_with_fs!(code)
      assert value == "caught"
    end

    test "with open() __exit__ does not suppress exceptions (matches CPython)" do
      code = """
      with open("test.txt", "w") as f:
          f.write("data")
          raise ValueError("should propagate")
      """

      assert {:error, msg} = run_with_fs!(code)
      assert msg =~ "ValueError"
    end
  end

  describe "os.listdir" do
    test "lists files in root directory" do
      fs = Memory.new(%{"a.txt" => "aaa", "b.txt" => "bbb"})

      code = """
      import os
      result = sorted(os.listdir())
      result
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == ["a.txt", "b.txt"]
    end

    test "lists files with explicit empty string path" do
      fs = Memory.new(%{"x.py" => "", "y.py" => ""})

      code = """
      import os
      result = sorted(os.listdir(""))
      result
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == ["x.py", "y.py"]
    end

    test "lists files in subdirectory" do
      fs =
        Memory.new(%{
          "src/main.py" => "",
          "src/utils.py" => "",
          "readme.txt" => ""
        })

      code = """
      import os
      result = sorted(os.listdir("src"))
      result
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == ["main.py", "utils.py"]
    end

    test "lists subdirectories as entries" do
      fs =
        Memory.new(%{
          "dir/sub/file.txt" => "",
          "dir/other.txt" => ""
        })

      code = """
      import os
      result = sorted(os.listdir("dir"))
      result
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == ["other.txt", "sub"]
    end

    test "returns empty list for empty directory" do
      fs = Memory.new()

      code = """
      import os
      os.listdir()
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == []
    end

    test "returns list type usable in for loop" do
      fs = Memory.new(%{"a.txt" => "", "b.txt" => "", "c.txt" => ""})

      code = """
      import os
      result = []
      for name in sorted(os.listdir()):
          result.append(name.upper())
      result
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == {:py_list, ["C.TXT", "B.TXT", "A.TXT"], 3}
    end

    test "result works with len()" do
      fs = Memory.new(%{"a.txt" => "", "b.txt" => ""})

      code = """
      import os
      len(os.listdir())
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == 2
    end

    test "result works with in operator" do
      fs = Memory.new(%{"target.txt" => "", "other.txt" => ""})

      code = """
      import os
      "target.txt" in os.listdir()
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == true
    end

    test "raises OSError when no filesystem configured" do
      code = """
      import os
      os.listdir()
      """

      ast = parse!(code)
      ctx = Ctx.new()

      assert {:error, msg} = Interpreter.run_with_ctx(ast, Builtins.env(), ctx)
      assert msg =~ "OSError"
      assert msg =~ "no filesystem configured"
    end

    test "raises TypeError for non-string argument" do
      fs = Memory.new()

      code = """
      import os
      os.listdir(123)
      """

      ast = parse!(code)
      ctx = Ctx.new(filesystem: fs)

      assert {:error, msg} = Interpreter.run_with_ctx(ast, Builtins.env(), ctx)
      assert msg =~ "TypeError"
    end

    test "works with list comprehension" do
      fs =
        Memory.new(%{
          "app.py" => "",
          "test.py" => "",
          "readme.md" => "",
          "config.json" => ""
        })

      code = """
      import os
      py_files = sorted([f for f in os.listdir() if f.endswith(".py")])
      py_files
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == ["app.py", "test.py"]
    end

    test "works after file creation" do
      code = """
      import os
      f = open("new_file.txt", "w")
      f.write("content")
      f.close()
      "new_file.txt" in os.listdir()
      """

      {value, _ctx} = run_with_fs!(code)
      assert value == true
    end

    test "callable attribute is callable" do
      fs = Memory.new()

      code = """
      import os
      callable(os.listdir)
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == true
    end

    test "listdir from os import" do
      fs = Memory.new(%{"file.txt" => ""})

      code = """
      from os import listdir
      sorted(listdir())
      """

      {value, _ctx} = run_with_fs!(code, fs)
      assert value == ["file.txt"]
    end
  end
end
