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
      {:ok, value, _env, ctx} -> {value, ctx}
      {:error, msg} -> {:error, msg}
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

    test "writing without close doesn't persist" do
      code = """
      f = open("test.txt", "w")
      f.write("not flushed")
      g = open("test.txt", "r")
      """

      assert {:error, msg} = run_with_fs!(code)
      assert msg =~ "FileNotFoundError"
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

      file_events =
        Ctx.events(ctx)
        |> Enum.filter(fn {type, _, _} -> type == :file_op end)

      assert length(file_events) >= 3

      ops = Enum.map(file_events, fn {_, _, data} -> elem(data, 0) end)
      assert :open in ops
      assert :read in ops
      assert :close in ops
    end

    test "no filesystem configured returns error" do
      ast = parse!(~s[f = open("test.txt", "r")])
      ctx = Ctx.new()

      assert {:error, msg} = Interpreter.run_with_ctx(ast, Builtins.env(), ctx)
      assert msg =~ "no filesystem"
    end
  end
end
