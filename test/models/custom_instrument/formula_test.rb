require "test_helper"

class CustomInstrument::FormulaTest < ActiveSupport::TestCase
  Reference = CustomInstrument::Formula::Reference
  ParseError = CustomInstrument::Formula::ParseError
  UNCHECKED = Object.new

  test "exposes the documented limits" do
    assert_equal 500, CustomInstrument::Formula::MAX_LENGTH
    assert_equal 20, CustomInstrument::Formula::MAX_DEPTH
    assert_equal 30, CustomInstrument::Formula::MAX_NUMBER_LENGTH
  end

  test "computes the quarter gold formula with exact rationals" do
    parsed = formula("1.754 * 0.9166 * XAU / 31.1034768")

    assert parsed.valid?
    assert_nil parsed.error
    assert_equal(
      { identifier("XAU") => Rational("1.754") * Rational("0.9166") / Rational("31.1034768") },
      parsed.weights
    )
  end

  test "returns frozen weights in first-appearance order" do
    parsed = formula("XAU + XAG + 2 * XAU")

    assert parsed.weights.frozen?
    assert_equal [ identifier("XAU"), identifier("XAG") ], parsed.references
    assert_equal parsed.weights.keys, parsed.references
    assert_equal Rational(3), parsed.weights[identifier("XAU")]
    assert_equal Rational(1), parsed.weights[identifier("XAG")]
  end

  test "keeps values as rationals and never floats" do
    assert_equal Rational(1, 50), formula("0.1 * 0.2 * XAU").weights[identifier("XAU")]
    assert_equal Rational(1, 3), formula("XAU / 3").weights[identifier("XAU")]
    assert_instance_of Rational, formula("XAU").weights[identifier("XAU")]
  end

  test "honours operator precedence" do
    assert_equal(
      { identifier("XAU") => Rational(1), identifier("XAG") => Rational(2) },
      formula("XAU + 2 * XAG").weights
    )
    assert_equal Rational(3, 2), formula("XAU / 2 * 3").weights[identifier("XAU")]
    assert_equal Rational(1, 6), formula("XAU / (2 * 3)").weights[identifier("XAU")]
    assert_equal(
      { identifier("XAU") => Rational(2), identifier("XAG") => Rational(2) },
      formula("2 * (XAU + XAG)").weights
    )
  end

  test "combines repeated references" do
    parsed = formula("2 * XAU - XAG + XAU")

    assert_equal [ identifier("XAU"), identifier("XAG") ], parsed.references
    assert_equal Rational(3), parsed.weights[identifier("XAU")]
    assert_equal Rational(-1), parsed.weights[identifier("XAG")]
  end

  test "supports unary signs" do
    assert_equal Rational(-1), formula("-XAU").weights[identifier("XAU")]
    assert_equal Rational(1), formula("- -XAU").weights[identifier("XAU")]
    assert_equal Rational(-2), formula("2 * -XAU").weights[identifier("XAU")]
    assert_equal(
      { identifier("XAU") => Rational(-1), identifier("XAG") => Rational(-1) },
      formula("-(XAU + XAG)").weights
    )
  end

  test "percent divides by one hundred" do
    assert_equal Rational(103, 100), formula("XAU * 103%").weights[identifier("XAU")]
    assert_equal Rational(1, 100), formula("XAU%").weights[identifier("XAU")]
    assert_equal(
      { identifier("XAU") => Rational(1, 100), identifier("XAG") => Rational(1, 100) },
      formula("(XAU + XAG)%").weights
    )
  end

  test "accepts typographic operators" do
    assert_equal Rational(2), formula("2 × XAU").weights[identifier("XAU")]
    assert_equal Rational(2), formula("2 · XAU").weights[identifier("XAU")]
    assert_equal Rational(1, 4), formula("XAU ÷ 4").weights[identifier("XAU")]
    assert_equal(
      { identifier("XAU") => Rational(1), identifier("XAG") => Rational(-1) },
      formula("XAU − XAG").weights
    )
  end

  test "treats x as an identifier instead of a multiplication operator" do
    assert_parse_error(:unexpected_token, "2 x XAU", position: 2, token: "x")
  end

  test "upcases unicode identifiers" do
    parsed = formula("çeyrek * 2")

    assert_equal [ identifier("ÇEYREK") ], parsed.references
    assert_equal Rational(2), parsed.weights[identifier("ÇEYREK")]
  end

  test "parses security references with an optional mic" do
    typed = formula("[thyao:xist] * 2")
    reference = security("THYAO", "XIST")

    assert_equal({ reference => Rational(2) }, typed.weights)
    assert_equal :security, reference.kind
    assert_equal "[THYAO:XIST]", reference.to_s
  end

  test "parses a security reference without a mic" do
    parsed = formula("[GC=F]")

    assert_equal [ security("GC=F") ], parsed.references
    assert_equal "[GC=F]", parsed.references.first.to_s
  end

  test "strips and upcases security content" do
    parsed = formula("2 * [ thyao:xist ]")

    assert_equal [ security("THYAO", "XIST") ], parsed.references
  end

  test "splits on the last colon only when the suffix is a mic" do
    assert_equal [ security("A:B", "XIST") ], formula("[A:B:XIST]").references
    assert_equal [ security("ABC:XYZ") ], formula("[ABC:XYZ]").references
    assert_equal [ security("GC", "1234") ], formula("[GC:1234]").references
  end

  test "accepts the documented security characters" do
    symbols = %w[BRK-B ^GSPC A_B A.B BRK/B A&B A=B]

    symbols.each do |symbol|
      parsed = formula("2 * [#{symbol}]")

      assert parsed.valid?, "#{symbol.inspect} should be allowed"
      assert_equal [ security(symbol) ], parsed.references
    end
  end

  test "percent applies to a security reference" do
    assert_equal Rational(1, 100), formula("[GC=F]%").weights[security("GC=F")]
  end

  test "ignores whitespace including newlines and tabs" do
    assert_equal(
      { identifier("XAU") => Rational(1), identifier("XAG") => Rational(1) },
      formula("\n\t XAU \r\n + \t XAG \n").weights
    )
  end

  test "drops zero weights and rejects formulas with no assets" do
    assert_equal [ identifier("XAG") ], formula("0 * XAU + XAG").references

    # Zero weights are dropped as soon as they are produced, so the left side
    # is a scalar and the product is legal; it simply has no assets left.
    assert_parse_error(:no_assets, "0 * XAU * XAG")
    assert_parse_error(:no_assets, "0 * XAU")
    assert_parse_error(:no_assets, "XAU * 0")
    assert_parse_error(:no_assets, "XAU - XAU")
    assert_parse_error(:no_assets, "5")
    assert_parse_error(:no_assets, "1 + 1")
  end

  test "allows a zero constant alongside assets" do
    assert_equal Rational(1), formula("XAU + 0").weights[identifier("XAU")]
    assert_equal Rational(1), formula("XAU + 5 - 5").weights[identifier("XAU")]
    assert_equal Rational(1), formula("(XAU + 5 - 5)").weights[identifier("XAU")]
  end

  test "rejects a leftover constant term" do
    assert_parse_error(:constant_term, "XAU + 5")
    assert_parse_error(:constant_term, "2 * XAU + 1")
    assert_parse_error(:constant_term, "XAU - 5")
  end

  test "rejects dividing by zero" do
    assert_parse_error(:divide_by_zero, "XAU / 0", position: 6, token: "0")
    assert_parse_error(:divide_by_zero, "XAU / 0.0")
    assert_parse_error(:divide_by_zero, "XAU / -0")
    assert_parse_error(:divide_by_zero, "XAU / (1 - 1)", position: 6, token: "(")
  end

  test "rejects dividing by an asset" do
    assert_parse_error(:divide_by_asset, "XAU / XAG", position: 6, token: "XAG")
  end

  test "rejects multiplying two assets" do
    assert_parse_error(:multiply_assets, "XAU * XAG", position: 6, token: "XAG")
    assert_parse_error(:multiply_assets, "2 * XAU * XAG", position: 10, token: "XAG")
    assert_parse_error(:multiply_assets, "(XAU + XAG) * XAU")
  end

  test "rejects a blank formula" do
    [ nil, "", "   ", "\n\t" ].each do |text|
      error = assert_parse_error(:blank, text)

      assert_nil error.position
      assert_nil error.token
    end
  end

  test "rejects an overly long formula" do
    assert_equal 500, ("XAU" + " " * 497).length
    assert formula("XAU" + " " * 497).valid?
    assert_parse_error(:too_long, "XAU" + " " * 498)

    # Whitespace-only text is blank rather than too long.
    assert_parse_error(:blank, " " * 501)
  end

  test "rejects numbers longer than the limit" do
    too_long = "1" * (CustomInstrument::Formula::MAX_NUMBER_LENGTH + 1)
    error = assert_parse_error(:number_too_long, "#{too_long} * XAU", position: 0)

    assert_equal too_long, error.token

    at_limit = "1" * CustomInstrument::Formula::MAX_NUMBER_LENGTH
    parsed = formula("#{at_limit} * XAU")

    assert parsed.valid?
    assert_equal Rational(at_limit), parsed.weights[identifier("XAU")]
  end

  test "rejects commas everywhere" do
    assert_parse_error(:comma, "1,5 * XAU", position: 1, token: ",")
    assert_parse_error(:comma, "1,000 * XAU", position: 1, token: ",")
    assert_parse_error(:comma, "[A,B]", position: 2, token: ",")
    assert_parse_error(:comma, "[GC=F] + 1,5 * XAG")
  end

  test "rejects scientific notation and other characters glued to numbers" do
    assert_parse_error(:unexpected_character, "1e5 * XAU", position: 1, token: "e")
    assert_parse_error(:unexpected_character, "1E5 * XAU", position: 1, token: "E")
    assert_parse_error(:unexpected_character, "2XAU", position: 1, token: "X")
  end

  test "rejects incomplete decimals" do
    assert_parse_error(:unexpected_character, "1.", position: 1, token: ".")
    assert_parse_error(:unexpected_character, ".5", position: 0, token: ".")
    assert_parse_error(:unexpected_character, "1..5", position: 1, token: ".")
    assert_parse_error(:unexpected_character, ".", position: 0, token: ".")
    assert_parse_error(:unexpected_character, "XAU + .5", position: 6, token: ".")
  end

  test "rejects a missing operator between values" do
    assert_parse_error(:unexpected_token, "2 XAU", position: 2, token: "XAU")
    assert_parse_error(:unexpected_token, "XAU XAG", position: 4, token: "XAG")
    assert_parse_error(:unexpected_token, "2 [GC=F]", position: 2, token: "[GC=F]")
  end

  test "rejects unexpected characters" do
    assert_parse_error(:unexpected_character, "XAU @", position: 4, token: "@")
    assert_parse_error(:unexpected_character, "XAU $ XAG", position: 4, token: "$")
  end

  test "rejects a second percent sign" do
    assert_parse_error(:unexpected_token, "50%%", position: 3, token: "%")
    assert_parse_error(:unexpected_token, "XAU %%", position: 5, token: "%")
  end

  test "rejects a formula that ends after an operator" do
    assert_parse_error(:unexpected_end, "XAU +", position: 5)
    assert_parse_error(:unexpected_end, "XAU *", position: 5)
  end

  test "rejects unbalanced parentheses" do
    assert_parse_error(:unbalanced_parenthesis, "(XAU", position: 4)
    assert_parse_error(:unbalanced_parenthesis, "((XAU)", position: 6)
    assert_parse_error(:unexpected_token, "XAU)", position: 3, token: ")")
    assert_parse_error(:unexpected_token, "(XAU + XAG))", position: 11, token: ")")
  end

  test "rejects missing or empty security references" do
    assert_parse_error(:unterminated_security, "2 * [GC=F", position: 4)
    assert_parse_error(:unterminated_security, "[GC=F * 2")
    assert_parse_error(:empty_security, "[]", position: 0)
    assert_parse_error(:empty_security, "[   ]", position: 0)
    assert_parse_error(:empty_security, "[:XIST]", position: 0)
  end

  test "rejects unsupported characters inside a security reference" do
    assert_parse_error(:unexpected_character, "[GC=F!]", position: 5, token: "!")
    assert_parse_error(:unexpected_character, "[GC=F?]", position: 5, token: "?")
  end

  test "counts nested parentheses towards the depth limit" do
    at_limit = "(" * 20 + "XAU" + ")" * 20
    assert formula(at_limit).valid?

    assert_parse_error(:too_deep, "(" * 21 + "XAU" + ")" * 21)
    # Long runs must fail on the depth limit, not overflow the stack, and stay
    # under MAX_LENGTH so depth is the first limit reached.
    assert_parse_error(:too_deep, "(" * 400)
    assert_parse_error(:too_deep, "(" * 400 + "XAU")
    assert_parse_error(:too_deep, "(" * 240 + "XAU" + ")" * 240)
  end

  test "counts chained unary signs towards the depth limit" do
    assert_equal Rational(1), formula("-" * 20 + "XAU").weights[identifier("XAU")]

    assert_parse_error(:too_deep, "-" * 21 + "XAU")
    assert_parse_error(:too_deep, "-" * 400 + "XAU")
  end

  test "raises parse errors from weights" do
    error = assert_raises(ParseError) { formula("XAU * XAG").weights }

    assert_equal :multiply_assets, error.code
    assert_equal 6, error.position
    assert_equal "XAG", error.token
  end

  test "reports 0-based positions and no position for semantic errors" do
    assert_equal 4, formula("XAU @").error.position

    semantic = formula("XAU + 5").error

    assert_equal :constant_term, semantic.code
    assert_nil semantic.position
    assert_nil semantic.token
  end

  test "localizes error messages at call time" do
    error = formula("XAU @").error

    english = I18n.with_locale(:en) { error.message }
    turkish = I18n.with_locale(:tr) { error.message }

    assert_includes english, "position 5"
    assert_includes english, "@"
    assert_includes turkish, "5"
    assert_includes turkish, "@"
    assert_not_equal english, turkish
  end

  test "comma message tells the user to use a dot" do
    error = formula("1,5 * XAU").error

    assert_includes I18n.with_locale(:en) { error.message }, "0.0517"
    turkish = I18n.with_locale(:tr) { error.message }

    assert_includes turkish, "0.0517"
    assert_includes turkish.downcase, "nokta"
  end

  test "builds references that round-trip to formula tokens" do
    identifier = identifier("XAU")
    no_mic = security("GC=F")
    with_mic = security("THYAO", "XIST")

    assert_equal :identifier, identifier.kind
    assert_nil identifier.mic
    assert_equal "XAU", identifier.to_s
    assert_equal "[GC=F]", no_mic.to_s
    assert_equal "[THYAO:XIST]", with_mic.to_s
    assert_equal with_mic, security("THYAO", "XIST")
    assert_not_equal with_mic, security("THYAO")
  end

  test "rename replaces identifier tokens and keeps everything else" do
    parsed = formula("1 * XAU + 2 * XAG + 3 * XAU")

    assert_equal "1 * XAUT + 2 * XAG + 3 * XAUT", parsed.rename("XAU", "XAUT")
  end

  test "rename is case-insensitive and keeps the untouched text as typed" do
    assert_equal "1 * XAUT", formula("1 * xAu").rename("xau", "XAUT")
    assert_equal "XAUT + xag", formula("xau + xag").rename("XAU", "XAUT")
  end

  test "rename matches whole tokens only" do
    assert_equal "XAU2 + XAUT", formula("XAU2 + XAU").rename("XAU", "XAUT")
  end

  test "rename never touches security references" do
    parsed = formula("XAU + [XAU:XIST]")

    assert_equal "XAUT + [XAU:XIST]", parsed.rename("XAU", "XAUT")
    assert_equal "XAU + [XAU:XIST]", parsed.rename("XIST", "XNAS")
  end

  test "rename preserves whitespace and newlines" do
    assert_equal "  XAUT\n + 1 * XAG ", formula("  XAU\n + 1 * XAG ").rename("XAU", "XAUT")
  end

  test "rename handles unicode identifiers" do
    assert_equal "CEYREK * 2", formula("çeyrek * 2").rename("çeyrek", "CEYREK")
    assert_equal "çeyrek + XAUT", formula("çeyrek + XAU").rename("XAU", "XAUT")
  end

  test "rename returns the text unchanged when nothing matches" do
    assert_equal "XAU + XAG", formula("XAU + XAG").rename("XAUT", "XAUZ")
    assert_equal "5 + XAUT", formula("5 + XAU").rename("XAU", "XAUT")
  end

  test "rename returns untokenizable text unchanged" do
    assert_equal "XAU, XAG", formula("XAU, XAG").rename("XAU", "XAUT")
  end

  test "rename handles a blank formula" do
    assert_equal "", formula(nil).rename("XAU", "XAUT")
  end

  private
    def formula(text)
      CustomInstrument::Formula.new(text)
    end

    def identifier(symbol)
      Reference.new(kind: :identifier, symbol: symbol, mic: nil)
    end

    def security(symbol, mic = nil)
      Reference.new(kind: :security, symbol: symbol, mic: mic)
    end

    def assert_parse_error(code, text, position: UNCHECKED, token: UNCHECKED)
      parsed = formula(text)

      assert_not parsed.valid?, "expected #{text.inspect} to be invalid"
      error = parsed.error

      assert_instance_of ParseError, error, "expected a ParseError for #{text.inspect}"
      assert_equal code, error.code, "unexpected code for #{text.inspect}"
      assert_equal position, error.position, "unexpected position for #{text.inspect}" unless position == UNCHECKED
      assert_equal token, error.token, "unexpected token for #{text.inspect}" unless token == UNCHECKED
      error
    end
end
