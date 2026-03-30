defmodule Pyex.Stdlib.String do
  @moduledoc """
  Python `string` module providing string constants.

  Includes `ascii_lowercase`, `ascii_uppercase`, `ascii_letters`,
  `digits`, `hexdigits`, `octdigits`, `punctuation`, `whitespace`,
  and `printable`.
  """

  @behaviour Pyex.Stdlib.Module

  @ascii_lowercase "abcdefghijklmnopqrstuvwxyz"
  @ascii_uppercase "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  @ascii_letters @ascii_lowercase <> @ascii_uppercase
  @digits "0123456789"
  @hexdigits "0123456789abcdefABCDEF"
  @octdigits "01234567"
  @punctuation "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
  @whitespace " \t\n\r\v\f"
  @printable @digits <> @ascii_letters <> @punctuation <> @whitespace

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "ascii_lowercase" => @ascii_lowercase,
      "ascii_uppercase" => @ascii_uppercase,
      "ascii_letters" => @ascii_letters,
      "digits" => @digits,
      "hexdigits" => @hexdigits,
      "octdigits" => @octdigits,
      "punctuation" => @punctuation,
      "whitespace" => @whitespace,
      "printable" => @printable
    }
  end
end
