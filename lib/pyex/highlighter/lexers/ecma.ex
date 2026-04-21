defmodule Pyex.Highlighter.Lexers.Ecma do
  @moduledoc """
  Shared rule builder for the ECMAScript language family:
  JavaScript, TypeScript, JSX, TSX.

  `rules/1` takes a keyword list of feature flags and returns a
  state-machine rule map:

      Pyex.Highlighter.Lexers.Ecma.rules(types: false, jsx: false)  # JS
      Pyex.Highlighter.Lexers.Ecma.rules(types: true,  jsx: false)  # TS
      Pyex.Highlighter.Lexers.Ecma.rules(types: false, jsx: true)   # JSX
      Pyex.Highlighter.Lexers.Ecma.rules(types: true,  jsx: true)   # TSX

  Features:

    * Common to all four: ES keywords, `const`/`let`/`var`, arrow
      functions, template literals with `${…}` interpolation (which
      pops back into JS-expression tokenization), regex literals
      (disambiguated from division by a small precedence heuristic),
      numbers (including bigint `n` suffix), block and line comments,
      single- and double-quoted strings, class/function names.

    * `types: true` adds: TS-specific keywords (`interface`, `type`,
      `enum`, `declare`, `abstract`, `keyof`, `readonly`, `as`,
      `satisfies`, `is`, `infer`, `namespace`, `module`, `unique`,
      `override`), primitive type names (`string`, `number`, `boolean`,
      `any`, `unknown`, `never`, `void`, `object`, `bigint`, `symbol`)
      tagged `Keyword.Type`.

    * `jsx: true` adds: a tag-opening rule that pushes a `:jsx_tag`
      state on `<LowercaseOrCapital>` at expression positions, with
      attribute + `{expr}` handling that pops back to the main state.
  """

  @js_keywords ~w(
    break case catch class const continue debugger default delete do else export
    extends finally for from function if import in instanceof let new of return
    super switch this throw try typeof var void while with yield await async
    static get set of
  )

  @js_reserved ~w(
    enum implements package private protected public arguments eval
  )

  @js_constants ~w(true false null undefined NaN Infinity)

  @js_builtins ~w(
    Array Boolean Date Error Function JSON Map Math Number Object Promise Proxy
    Reflect RegExp Set String Symbol WeakMap WeakSet BigInt DataView
    ArrayBuffer Uint8Array Uint16Array Uint32Array Int8Array Int16Array
    Int32Array Float32Array Float64Array BigInt64Array BigUint64Array
    console process globalThis document window
  )

  @ts_keywords ~w(
    interface type enum declare abstract keyof readonly as satisfies is infer
    namespace module unique override
  )

  @ts_primitive_types ~w(
    string number boolean any unknown never void object bigint symbol undefined
  )

  @doc """
  Builds a rule map for an ECMAScript variant.

  Options:

    * `:types` (boolean, default `false`) — include TypeScript rules
    * `:jsx` (boolean, default `false`) — include JSX tag rules
  """
  @spec rules(keyword()) :: Pyex.Highlighter.Lexer.rules()
  def rules(opts \\ []) do
    types? = Keyword.get(opts, :types, false)
    jsx? = Keyword.get(opts, :jsx, false)

    base_root = root_rules(types?, jsx?)

    common = %{
      root: base_root,
      tplstring: tplstring_rules(),
      interp: interp_rules(types?, jsx?)
    }

    common
    |> maybe_merge(types?, type_rules())
    |> maybe_merge(jsx?, jsx_rules())
  end

  defp maybe_merge(map, true, extra), do: Map.merge(map, extra)
  defp maybe_merge(map, false, _extra), do: map

  defp root_rules(types?, jsx?) do
    [
      # Comments first — otherwise the regex-literal rule wrongly
      # swallows `/* ... */`.
      {~r/\/\/[^\n]*/, :comment_single, :none},
      {~r/\/\*[\s\S]*?\*\//, :comment_multiline, :none},
      {~r/\s+/u, :whitespace, :none}
    ] ++
      if(types?, do: type_keyword_rules(), else: []) ++
      keyword_rules() ++
      constant_rules() ++
      name_rules() ++
      number_rules() ++
      string_rules() ++
      [
        # Template literals
        {~r/`/, :string_backtick, {:push, :tplstring}}
      ] ++
      regex_rule() ++
      if(jsx?, do: jsx_opening_rule(), else: []) ++
      [
        # Operators (longest first)
        {~r/\?\?=|\?\?|\?\.|\.\.\.|=>|===|!==|==|!=|<=|>=|<<=|>>=|>>>=|>>>|<<|>>|&&=|\|\|=|&&|\|\||\*\*=|\*\*|\+\+|--|\+=|-=|\*=|\/=|%=|&=|\|=|\^=|[+\-*\/%=<>!&|^~?:]/,
         :operator, :none},
        # Punctuation
        {~r/[(){}\[\];,.@]/, :punctuation, :none}
      ] ++
      if jsx? do
        # In JSX mode, text between tags (incl. unicode like `…`, `·`,
        # plus stray `#` in `<em>hello #4</em>`) should tag as :text
        # rather than fall through to :error.
        [{~r/[^\s<>{}()\[\];,.@"'`\/\\*+\-=!?&|^~%:]+/u, :text, :none}]
      else
        []
      end
  end

  defp keyword_rules do
    [
      {Regex.compile!("\\b(?:" <> Enum.join(@js_keywords, "|") <> ")\\b"), :keyword, :none},
      {Regex.compile!("\\b(?:" <> Enum.join(@js_reserved, "|") <> ")\\b"), :keyword_reserved,
       :none}
    ]
  end

  defp constant_rules do
    [
      {Regex.compile!("\\b(?:" <> Enum.join(@js_constants, "|") <> ")\\b"), :keyword_constant,
       :none}
    ]
  end

  defp type_keyword_rules do
    [
      {Regex.compile!("\\b(?:" <> Enum.join(@ts_keywords, "|") <> ")\\b"), :keyword_declaration,
       :none},
      {Regex.compile!("\\b(?:" <> Enum.join(@ts_primitive_types, "|") <> ")\\b"), :keyword_type,
       :none}
    ]
  end

  defp name_rules do
    [
      # Function declarations: `function name(`
      {~r/(function\s*\*?)(\s+)([A-Za-z_$][\w$]*)/,
       {:bygroups, [:keyword, :whitespace, :name_function]}, :none},

      # Class declarations
      {~r/(class)(\s+)([A-Za-z_$][\w$]*)/, {:bygroups, [:keyword, :whitespace, :name_class]},
       :none},

      # Private class fields / methods: `#name`. Valid in class bodies.
      {~r/#[A-Za-z_$][\w$]*/, :name_variable_instance, :none},

      # Built-in globals
      {Regex.compile!("\\b(?:" <> Enum.join(@js_builtins, "|") <> ")\\b"), :name_builtin, :none},

      # Decorators
      {~r/@[A-Za-z_$][\w$]*/, :name_decorator, :none},

      # Function call: identifier followed by `(`
      {~r/[A-Za-z_$][\w$]*(?=\s*\()/, :name_function, :none},

      # CamelCase — likely a class or constructor
      {~r/[A-Z][\w$]*/, :name_class, :none},

      # Plain identifiers
      {~r/[A-Za-z_$][\w$]*/, :name, :none}
    ]
  end

  defp number_rules do
    [
      # Hex/oct/bin with optional bigint suffix
      {~r/0[xX][0-9a-fA-F](?:_?[0-9a-fA-F])*n?/, :number_hex, :none},
      {~r/0[oO][0-7](?:_?[0-7])*n?/, :number_oct, :none},
      {~r/0[bB][01](?:_?[01])*n?/, :number_bin, :none},
      # Float: with decimal point or exponent
      {~r/\d(?:_?\d)*\.\d(?:_?\d)*(?:[eE][+-]?\d+)?/, :number_float, :none},
      {~r/\d(?:_?\d)*[eE][+-]?\d+/, :number_float, :none},
      {~r/\.\d(?:_?\d)*(?:[eE][+-]?\d+)?/, :number_float, :none},
      # Integer with optional bigint suffix
      {~r/\d(?:_?\d)*n?/, :number_integer, :none}
    ]
  end

  defp string_rules do
    [
      {~r/"(?:\\.|[^"\\\n])*"/, :string_double, :none},
      {~r/'(?:\\.|[^'\\\n])*'/, :string_single, :none}
    ]
  end

  # Regex-literal disambiguation: `/` is a regex iff it appears at an
  # expression-start position. We avoid variable-width lookbehind (which
  # PCRE restricts) by consuming the preceding operator or keyword with
  # `bygroups`, then emitting each piece with the right token type.
  #
  # This fires in three contexts:
  #   1. after an operator/opening punct (with optional whitespace)
  #   2. after `return` / `typeof` / `in` / `of` keywords
  #   3. at the very start of input
  defp regex_rule do
    body = ~S"\/(?:\\.|\[(?:\\.|[^\]\\])*\]|[^\/\\\n])+\/[gimsuvy]*"

    [
      # (1) After an operator. We match the operator char, optional ws,
      # then the regex. Emit as three tokens.
      {Regex.compile!("([=(,;:!&|?+\\-*%{}])(\\s*)(" <> body <> ")"),
       {:bygroups, [:operator, :whitespace, :string_regex]}, :none},
      # (2) After a keyword.
      {Regex.compile!("(\\breturn\\b|\\btypeof\\b|\\bin\\b|\\bof\\b)(\\s+)(" <> body <> ")"),
       {:bygroups, [:keyword, :whitespace, :string_regex]}, :none},
      # (3) At the start of input.
      {Regex.compile!("\\A(" <> body <> ")"), {:bygroups, [:string_regex]}, :none}
    ]
  end

  # ------- template string state -------
  defp tplstring_rules do
    [
      {~r/`/, :string_backtick, :pop},
      {~r/\\./, :string_escape, :none},
      {~r/\$\{/, :string_interpol, {:push, :interp}},
      {~r/\$(?!\{)/, :string_backtick, :none},
      {~r/[^`\\$]+/, :string_backtick, :none}
    ]
  end

  # ------- interpolation state (inside ${…}) -------
  defp interp_rules(types?, jsx?) do
    [
      {~r/\}/, :string_interpol, :pop},
      # Recurse into a simpler JS-like tokenization. We don't track
      # nested braces here — `${ {a:1}.a }` would break. Shallow is OK
      # for a highlighter; depth tracking is a future upgrade.
      {~r/\{/, :punctuation, :push_same}
    ] ++
      keyword_rules() ++
      constant_rules() ++
      if(types?, do: type_keyword_rules(), else: []) ++
      name_rules() ++
      number_rules() ++
      string_rules() ++
      [
        {~r/`/, :string_backtick, {:push, :tplstring}},
        {~r/\/\/[^\n]*/, :comment_single, :none},
        {~r/\/\*[\s\S]*?\*\//, :comment_multiline, :none},
        {~r/\s+/u, :whitespace, :none},
        {~r/\?\?=|\?\?|\?\.|\.\.\.|=>|===|!==|==|!=|<=|>=|<<=|>>=|>>>=|>>>|<<|>>|&&=|\|\|=|&&|\|\||\*\*=|\*\*|\+\+|--|\+=|-=|\*=|\/=|%=|&=|\|=|\^=|[+\-*\/%=<>!&|^~?:]/,
         :operator, :none},
        {~r/[()\[\];,.@]/, :punctuation, :none}
      ] ++ if(jsx?, do: jsx_opening_rule(), else: [])
  end

  # ------- TypeScript additions -------
  defp type_rules do
    %{}
  end

  # ------- JSX rules -------
  defp jsx_opening_rule do
    [
      # Closing tag `</Tag` — push jsx_tag so trailing whitespace + `>`
      # are consumed consistently.
      {~r/<\/[A-Za-z][\w.-]*/, :name_tag, {:push, :jsx_tag}},
      # Closing / opening fragments.
      {~r/<\/>/, :punctuation, :none},
      {~r/<>/, :punctuation, :none},
      # Opening `<Tag`. Require the next character to be whitespace, `/`,
      # or `>` — this disambiguates JSX from TS generic calls like
      # `ComponentType<{...}>` or `Array<User>`, where `<Identifier` is
      # followed by `<` or `,` rather than attributes.
      {~r/<[A-Za-z][\w.-]*(?=[\s\/>])/, :name_tag, {:push, :jsx_tag}}
    ]
  end

  defp jsx_rules do
    %{
      jsx_tag: [
        # Self-closing / close tag
        {~r/\/?>/, :punctuation, :pop},
        {~r/\s+/u, :whitespace, :none},
        # Spread attribute: `{...rest}`
        {~r/\{\.\.\./, :string_interpol, {:push, :jsx_attr_interp}},
        # attr={expr}
        {~r/([A-Za-z_][\w-]*)(=)(\{)/,
         {:bygroups, [:name_attribute, :operator, :string_interpol]}, {:push, :jsx_attr_interp}},
        # attr="string"
        {~r/([A-Za-z_][\w-]*)(=)("(?:\\.|[^"\\])*")/,
         {:bygroups, [:name_attribute, :operator, :string_double]}, :none},
        # attr='string'
        {~r/([A-Za-z_][\w-]*)(=)('(?:\\.|[^'\\])*')/,
         {:bygroups, [:name_attribute, :operator, :string_single]}, :none},
        # attr (boolean)
        {~r/[A-Za-z_][\w-]*/, :name_attribute, :none}
      ],
      jsx_attr_interp:
        [
          # Inside `{…}` in an attribute — track nesting.
          {~r/\}/, :string_interpol, :pop},
          {~r/\{/, :punctuation, :push_same},
          # Template literals (with their own `${…}` interpolations).
          {~r/`/, :string_backtick, {:push, :tplstring}}
        ] ++
          keyword_rules() ++
          constant_rules() ++
          name_rules() ++
          number_rules() ++
          string_rules() ++
          [
            {~r/\/\/[^\n]*/, :comment_single, :none},
            {~r/\/\*[\s\S]*?\*\//, :comment_multiline, :none},
            {~r/\s+/u, :whitespace, :none},
            {~r/=>|===|!==|\?\?|\?\.|\.\.\.|==|!=|<=|>=|&&|\|\||[+\-*\/%=<>!&|^~?:,.]/, :operator,
             :none},
            {~r/[()\[\]]/, :punctuation, :none}
          ]
    }
  end
end
