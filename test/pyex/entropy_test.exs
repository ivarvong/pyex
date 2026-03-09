defmodule Pyex.EntropyTest do
  use ExUnit.Case, async: true

  doctest Pyex.Entropy

  alias Pyex.Entropy

  describe "shannon/1" do
    test "returns expected values for simple inputs" do
      assert Entropy.shannon("aaaa") == 0.0
      assert Entropy.shannon("abcd") == 2.0
      assert Entropy.shannon(<<>>) == 0.0
    end
  end

  describe "builtin_matchers/0" do
    test "includes major cloud and llm providers" do
      keys = Entropy.builtin_matchers() |> Map.keys() |> MapSet.new()

      for key <- [
            :aws_access_key,
            :aws_secret_key,
            :google_api_key,
            :azure_storage_connection_string,
            :openai_key,
            :anthropic_key,
            :openrouter_key,
            :groq_key,
            :huggingface_token
          ] do
        assert MapSet.member?(keys, key)
      end
    end
  end

  describe "scan/2" do
    test "detects high-entropy input smaller than the window" do
      input = :binary.list_to_bin(Enum.to_list(0..15))

      assert [%{offset: 0, matcher: nil, window: ^input}] =
               Entropy.scan(input, window_size: 64, threshold: 3.5)
    end

    test "detects provider secrets with builtin matchers" do
      samples = [
        {:aws_access_key, "AKIA" <> String.duplicate("A", 16)},
        {:aws_secret_key, ~s(aws_secret_access_key=") <> String.duplicate("A", 40) <> ~s(")},
        {:google_api_key, "AIza" <> String.duplicate("A", 35)},
        {:azure_storage_connection_string,
         "DefaultEndpointsProtocol=https;AccountName=demo;AccountKey=" <>
           Base.encode64(String.duplicate("a", 24)) <> ";EndpointSuffix=core.windows.net"},
        {:openai_key, "sk-proj-" <> String.duplicate("a", 24)},
        {:anthropic_key, "sk-ant-" <> String.duplicate("a", 24)},
        {:openrouter_key, "sk-or-v1-" <> String.duplicate("a", 24)},
        {:groq_key, "gsk_" <> String.duplicate("A", 24)},
        {:huggingface_token, "hf_" <> String.duplicate("A", 30)}
      ]

      Enum.each(samples, fn {matcher, sample} ->
        assert Enum.any?(
                 Entropy.scan(sample, builtins: true, threshold: 99.0, window_size: 256),
                 &(&1.matcher == matcher)
               )
      end)
    end

    test "rejects invalid window sizes" do
      assert_raise ArgumentError, ~r/window_size must be a positive integer/, fn ->
        Entropy.scan("abc", window_size: 0)
      end
    end

    test "rejects invalid matcher collections" do
      assert_raise ArgumentError, ~r/matchers must be a map/, fn ->
        Entropy.scan("abc", matchers: [:not_a_map])
      end
    end
  end
end
