class CustomInstrument::Formula
  MAX_LENGTH = 500
  MAX_DEPTH = 20
  MAX_NUMBER_LENGTH = 30

  IDENTIFIER_START = /\A\p{L}\z/
  IDENTIFIER_CHARACTER = /\A[\p{L}\p{N}_]\z/
  DIGIT = /\A[0-9]\z/
  MIC = /\A[A-Z0-9]{4}\z/
  SECURITY_CHARACTER = %r{\A[\p{L}\p{N}.=^_/:& -]\z}

  class ParseError < StandardError
    attr_reader :code, :position, :token

    def initialize(code, position: nil, token: nil)
      @code = code
      @position = position
      @token = token
      super()
    end

    def message
      I18n.t(
        "custom_instruments.formula.errors.#{code}",
        token: token,
        position: position && position + 1
      )
    end
  end

  Reference = Data.define(:kind, :symbol, :mic) do
    def to_s
      return symbol unless kind == :security

      mic.present? ? "[#{symbol}:#{mic}]" : "[#{symbol}]"
    end
  end

  Token = Data.define(:type, :text, :position, :value)

  def initialize(text)
    @text = text.to_s
  end

  def valid?
    weights
    @error = nil
    true
  rescue ParseError => error
    @error = error
    false
  end

  def error
    valid?
    @error
  end

  def weights
    @weights ||= begin
      raise ParseError.new(:blank) if @text.strip.empty?
      raise ParseError.new(:too_long) if @text.length > MAX_LENGTH

      value = Parser.new(tokenize).parse
      parsed_weights = value[:weights]
      raise ParseError.new(:no_assets) if parsed_weights.empty?
      raise ParseError.new(:constant_term) unless value[:constant].zero?

      parsed_weights.freeze
    end
  end

  def references
    weights.keys
  end

  # Replaces identifier tokens only, so security references and substrings such
  # as XAU2 stay untouched. Text that does not tokenize is returned unchanged.
  def rename(old_symbol, new_symbol)
    target = old_symbol.to_s.strip.upcase
    replacement = new_symbol.to_s
    result = +""
    cursor = 0

    tokenize.each do |token|
      next unless token.type == :identifier && token.value == target

      result << @text[cursor...token.position] << replacement
      cursor = token.position + token.text.length
    end

    result << @text[cursor..]
    result
  rescue ParseError
    @text
  end

  private
    def tokenize
      tokens = []
      index = 0

      while index < @text.length
        character = @text[index]

        case character
        when " ", "\t", "\n", "\r"
          index += 1
        when ","
          raise ParseError.new(:comma, position: index, token: character)
        when "+"
          tokens << Token.new(:plus, character, index, nil)
          index += 1
        when "-", "\u2212"
          tokens << Token.new(:minus, character, index, nil)
          index += 1
        when "*", "×", "·"
          tokens << Token.new(:star, character, index, nil)
          index += 1
        when "/", "÷"
          tokens << Token.new(:slash, character, index, nil)
          index += 1
        when "%"
          tokens << Token.new(:percent, character, index, nil)
          index += 1
        when "("
          tokens << Token.new(:lparen, character, index, nil)
          index += 1
        when ")"
          tokens << Token.new(:rparen, character, index, nil)
          index += 1
        when "["
          token, index = scan_security(index)
          tokens << token
        else
          if digit?(character)
            token, index = scan_number(index)
            tokens << token
          elsif identifier_start?(character)
            token, index = scan_identifier(index)
            tokens << token
          else
            raise ParseError.new(:unexpected_character, position: index, token: character)
          end
        end
      end

      tokens << Token.new(:eof, nil, @text.length, nil)
      tokens
    end

    def scan_number(start)
      index = start
      index += 1 while index < @text.length && digit?(@text[index])

      if index < @text.length && @text[index] == "."
        dot = index
        index += 1
        digits_start = index
        index += 1 while index < @text.length && digit?(@text[index])
        raise ParseError.new(:unexpected_character, position: dot, token: ".") if index == digits_start
      end

      text = @text[start...index]

      if text.length > MAX_NUMBER_LENGTH
        raise ParseError.new(:number_too_long, position: start, token: text)
      end

      # Catches scientific notation ("1e5") instead of silently splitting off
      # an identifier, and anything else glued to the number.
      if index < @text.length && identifier_start?(@text[index])
        raise ParseError.new(:unexpected_character, position: index, token: @text[index])
      end

      [ Token.new(:number, text, start, Rational(text)), index ]
    end

    def scan_identifier(start)
      index = start + 1
      index += 1 while index < @text.length && identifier_character?(@text[index])

      text = @text[start...index]
      [ Token.new(:identifier, text, start, text.upcase), index ]
    end

    def scan_security(start)
      closing = @text.index("]", start + 1)
      raise ParseError.new(:unterminated_security, position: start) unless closing

      (start + 1).upto(closing - 1) do |index|
        character = @text[index]
        next if character.match?(SECURITY_CHARACTER)
        raise ParseError.new(:comma, position: index, token: character) if character == ","

        raise ParseError.new(:unexpected_character, position: index, token: character)
      end

      content = @text[(start + 1)...closing].strip.upcase
      raise ParseError.new(:empty_security, position: start) if content.empty?

      reference = security_reference(content, start)
      index = closing + 1

      [ Token.new(:security, @text[start...index], start, reference), index ]
    end

    def security_reference(content, position)
      colon = content.rindex(":")
      mic = colon && content[(colon + 1)..]

      if mic&.match?(MIC)
        symbol = content[0...colon]
      else
        symbol = content
        mic = nil
      end

      raise ParseError.new(:empty_security, position: position) if symbol.empty?

      Reference.new(kind: :security, symbol: symbol, mic: mic)
    end

    def digit?(character)
      character.match?(DIGIT)
    end

    def identifier_start?(character)
      character.match?(IDENTIFIER_START)
    end

    def identifier_character?(character)
      character.match?(IDENTIFIER_CHARACTER)
    end

    class Parser
      def initialize(tokens)
        @tokens = tokens
        @index = 0
        @depth = 0
      end

      def parse
        value = parse_expression
        token = current
        raise ParseError.new(:unexpected_token, position: token.position, token: token.text) unless token.type == :eof

        value
      end

      private
        def parse_expression
          value = parse_term

          loop do
            operator = current
            break unless operator.type == :plus || operator.type == :minus

            advance
            term = parse_term
            value = combine(value, term, operator.type == :minus ? -1 : 1)
          end

          value
        end

        def parse_term
          value = parse_factor

          loop do
            operator = current
            break unless operator.type == :star || operator.type == :slash

            advance
            operand = current
            factor = parse_factor
            value = operator.type == :star ? multiply(value, factor, operand) : divide(value, factor, operand)
          end

          value
        end

        def parse_factor
          token = current

          if token.type == :plus || token.type == :minus
            advance
            value = nested { parse_factor }
            value = scale(value, Rational(-1)) if token.type == :minus
          else
            value = parse_primary
          end

          if current.type == :percent
            advance
            value = scale(value, Rational(1, 100))
          end

          value
        end

        def parse_primary
          token = current

          case token.type
          when :number
            advance
            { constant: token.value, weights: {} }
          when :identifier
            advance
            asset(Reference.new(kind: :identifier, symbol: token.value, mic: nil))
          when :security
            advance
            asset(token.value)
          when :lparen
            parse_parenthesized
          when :eof
            raise ParseError.new(:unexpected_end, position: token.position)
          else
            raise ParseError.new(:unexpected_token, position: token.position, token: token.text)
          end
        end

        def parse_parenthesized
          advance
          value = nested { parse_expression }
          closing = current

          unless closing.type == :rparen
            code = closing.type == :eof ? :unbalanced_parenthesis : :unexpected_token
            raise ParseError.new(code, position: closing.position, token: closing.text)
          end

          advance
          value
        end

        # Nesting covers chained unary signs too, so long chains fail on the
        # depth limit instead of exhausting the Ruby stack.
        def nested
          @depth += 1
          raise ParseError.new(:too_deep, position: current.position) if @depth > MAX_DEPTH

          yield
        ensure
          @depth -= 1
        end

        def asset(reference)
          { constant: Rational(0), weights: { reference => Rational(1) } }
        end

        def combine(left, right, sign)
          weights = left[:weights].dup

          right[:weights].each do |reference, weight|
            weights[reference] = (weights[reference] || 0) + weight * sign
          end
          weights.reject! { |_reference, weight| weight.zero? }

          { constant: left[:constant] + right[:constant] * sign, weights: weights }
        end

        # A zero factor drops references immediately, so "has no references" is
        # the scalar test: 0 * XAU counts as a scalar, and 0 * XAU * XAG ends as
        # :no_assets rather than :multiply_assets.
        def scale(value, factor)
          weights = {}

          value[:weights].each do |reference, weight|
            scaled = weight * factor
            weights[reference] = scaled unless scaled.zero?
          end

          { constant: value[:constant] * factor, weights: weights }
        end

        def multiply(left, right, operand)
          if scalar?(left)
            scale(right, left[:constant])
          elsif scalar?(right)
            scale(left, right[:constant])
          else
            raise ParseError.new(:multiply_assets, position: operand.position, token: operand.text)
          end
        end

        def divide(left, right, operand)
          unless scalar?(right)
            raise ParseError.new(:divide_by_asset, position: operand.position, token: operand.text)
          end
          if right[:constant].zero?
            raise ParseError.new(:divide_by_zero, position: operand.position, token: operand.text)
          end

          scale(left, Rational(1, 1) / right[:constant])
        end

        def scalar?(value)
          value[:weights].empty?
        end

        def current
          @tokens[@index]
        end

        def advance
          token = current
          @index += 1
          token
        end
    end
end
