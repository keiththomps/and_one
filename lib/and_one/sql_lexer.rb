# frozen_string_literal: true

require "strscan"

module AndOne
  # A lexical scanner, not a SQL parser. Unknown syntax is retained, not discarded.
  class SqlLexer
    Token = Struct.new(:kind, :text)
    NUMBER = /(?:0[xX][0-9a-fA-F]+|0[bB][01]+|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)/
    WORD = /[\p{L}_][\p{L}\p{N}_$]*/
    OPERATOR = %r{::|->>|->|#>>|#>|\?\||\?&|<=|>=|<>|!=|\|\||&&|:=|[-+*/%<>=~!@#^&|?]}

    def initialize(sql, adapter: nil)
      @scanner = StringScanner.new(sql)
      @mysql = adapter.to_s.match?(/mysql|trilogy/i)
      @sqlite = adapter.to_s.match?(/sqlite/i)
      @postgres = adapter.to_s.match?(/postgres/i)
      @ambiguous_quotes = @sqlite || adapter.nil? || adapter.to_s == "unknown"
    end

    def tokens
      result = []
      until @scanner.eos?
        next if @scanner.scan(/\s+/)

        token = next_token
        result << token if token
      end
      result
    end

    # Preserve SQL layout for display, but never emit literals, comments or
    # unsupported/unterminated tokens. Fingerprinting intentionally differs.
    def redacted
      @redacting = true
      output = +""
      previous = nil
      until @scanner.eos?
        whitespace = @scanner.scan(/\s+/)
        if whitespace
          output << whitespace
          next
        end
        start = @scanner.pos
        token = next_token
        output << if token.nil? || %i[parameter opaque].include?(token.kind) || ambiguous_identifier?(token, previous)
                    "?"
                  else
                    @scanner.string.byteslice(start...@scanner.pos)
                  end
        previous = token if token
      end
      output
    end

    # Feed original lexical values directly into a keyed digest; never return
    # them or attach them to retained tokens. Reject ambiguous SQL entirely.
    def signature_into?(digest, binds)
      index = 0
      previous = nil
      until @scanner.eos?
        next if @scanner.scan(/\s+/)

        start = @scanner.pos
        token = next_token
        next unless token
        return false if token.kind == :opaque

        raw = @scanner.string.byteslice(start...@scanner.pos)
        return false if raw.include?("\\") || ambiguous_identifier?(token, previous)

        previous = token

        if token.kind == :parameter && raw.match?(/\A(?:\$\d+|\?\d*|[:@$][A-Za-z_]\w*)\z/)
          return false unless binds && index < binds.size
          return false unless ["?", "$#{index + 1}", "?#{index + 1}"].include?(raw)

          digest << "bind:#{binds[index].bytesize}:" << binds[index]
          index += 1
        else
          value = token.kind == :parameter ? raw : token.text
          digest << "#{token.kind}:#{value.bytesize}:" << value
        end
      end
      !binds || index == binds.size
    end

    private

    def ambiguous_identifier?(token, previous)
      return false unless @ambiguous_quotes && token.kind == :identifier && token.text.start_with?('"')
      return false if @scanner.check(/\s*\./) || previous&.text == "."

      !%w[from join as].include?(previous&.text)
    end

    def next_token
      return block_comment if @scanner.peek(2) == "/*"
      return line_comment if line_comment?
      return quoted_literal if @scanner.check(/(?:[eEnNbBxX])?'/)
      return dollar_literal if @scanner.check(/\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$/)
      return quoted_identifier if @scanner.check(/["`]/) || (@sqlite && @scanner.peek(1) == "[")
      return Token.new(:parameter, "?") if parameter?
      return Token.new(:parameter, "?") if @scanner.scan(NUMBER)

      word = @scanner.scan(WORD)
      return word_token(word) if word

      Token.new(:symbol, @scanner.scan(OPERATOR) || @scanner.getch)
    end

    def line_comment?
      (@scanner.peek(2) == "--" && (!@mysql || @scanner.check(/--(?:\s|\z)/))) ||
        (@mysql && @scanner.peek(1) == "#")
    end

    def line_comment
      @scanner.scan(/[^\r\n]*/)
      nil
    end

    def block_comment
      start = @scanner.pos
      @scanner.pos += 2
      significant = @scanner.check(/[!+]/)
      depth = 1
      while depth.positive? && !@scanner.eos?
        delimiter = @scanner.scan_until(%r{/\*|\*/})
        unless delimiter
          @scanner.terminate
          break
        end
        depth += delimiter.end_with?("/*") ? 1 : -1
      end
      # Executable comments and optimizer hints must not be erased as trivia.
      raw_token(start, :opaque) if significant || depth.positive?
    end

    def quoted_literal
      start = @scanner.pos
      prefix = @scanner.scan(/[eEnNbBxX](?=')/)
      escaped = @mysql || prefix&.casecmp?("e")
      closed = consume_quoted?("'", escaped: escaped)
      # Session-dependent backslash rules can make the closing quote ambiguous.
      # Mask the remainder rather than accidentally emitting part of a literal.
      @scanner.terminate if @redacting && @scanner.string.byteslice(start...@scanner.pos).include?("\\")
      closed ? Token.new(:parameter, "?") : raw_token(start, :opaque)
    end

    def dollar_literal
      start = @scanner.pos
      delimiter = @scanner.scan(/\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$/)
      if @scanner.scan_until(Regexp.new(Regexp.escape(delimiter)))
        Token.new(:parameter, "?")
      else
        @scanner.terminate
        raw_token(start, :opaque)
      end
    end

    def quoted_identifier
      start = @scanner.pos
      opening = @scanner.peek(1)
      closing = opening == "[" ? "]" : opening
      closed = consume_quoted?(closing, escaped: @mysql)
      if @redacting && @scanner.string.byteslice(start...@scanner.pos).include?("\\")
        @scanner.terminate
        return Token.new(:parameter, "?")
      end
      if closed && @mysql && opening == '"'
        Token.new(:parameter, "?")
      else
        raw_token(start, closed ? :identifier : :opaque)
      end
    end

    def consume_quoted?(closing, escaped:)
      @scanner.getch
      until @scanner.eos?
        character = @scanner.getch
        if escaped && character == "\\"
          @scanner.getch
        elsif character == closing
          return true unless @scanner.peek(1) == closing

          @scanner.getch # SQL doubled quote escape
        end
      end
      false
    end

    def parameter?
      return true if @scanner.scan(/\$\d+/)
      return true if @sqlite && @scanner.scan(/(?:[:@$][A-Za-z_][A-Za-z_0-9]*|\?\d*)/)

      !@postgres && @scanner.scan(/\?(?![|&])/)
    end

    def word_token(word)
      normalized = word.downcase
      kind = %w[true false].include?(normalized) ? :parameter : :word
      Token.new(kind, kind == :parameter ? "?" : normalized)
    end

    def raw_token(start, kind)
      Token.new(kind, @scanner.string.byteslice(start...@scanner.pos))
    end
  end
end
