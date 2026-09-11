# frozen_string_literal: true

require "openssl"
require "securerandom"
require_relative "query_evidence"

module AndOne
  # One digest and two flags per group, independent of occurrence/value count.
  # The random scan key is never serialized, preventing offline value guessing.
  class RepetitionEvidence
    MAX_BYTES = 8192
    MAX_BINDS = 64

    def initialize
      @missing = false
      @varying = false
    end

    def record(sql, payload, adapter, key)
      @structure ||= structure(sql, adapter)
      signature = signature(sql, payload[:type_casted_binds], adapter, key)
      @missing ||= signature.nil?
      @varying ||= @first && signature && @first != signature
      @first ||= signature # rubocop:disable Naming/MemoizedInstanceVariableName
    end

    def classification
      return %i[repeated_aggregate observed] if @structure == :aggregate
      return %i[generic_repetition unknown] if @missing || !@first
      return %i[duplicate_identical_read observed] unless @varying

      return %i[suspected_association_n_plus_one candidate] if @structure == :records

      %i[generic_repetition unknown]
    end

    private

    def structure(sql, adapter)
      return :unknown if sql.bytesize > MAX_BYTES

      evidence = QueryEvidence.new(sql, adapter: adapter)
      return :aggregate if %i[count exists aggregate].include?(evidence.operation)

      table = sql[/\bFROM\s+["`]?(\w+)["`]?/i, 1]
      return :records if evidence.operation == :records && evidence.simple? && !evidence.predicate_columns(table).empty?

      :unknown
    end

    def signature(sql, binds, adapter, key)
      return if sql.bytesize > MAX_BYTES
      return unless binds.nil? || (binds.instance_of?(Array) && binds.size <= MAX_BINDS)

      encoded = binds&.map { |value| encode(value) }
      return if encoded && (encoded.any?(&:nil?) || encoded.sum(&:bytesize) > MAX_BYTES)

      digest = OpenSSL::HMAC.new(key, "SHA256")
      digest.digest if SqlLexer.new(sql, adapter: adapter).signature_into?(digest, encoded)
    end

    def encode(value)
      case value.class.name
      when "String"
        "string:#{value.b}" if value.bytesize <= MAX_BYTES
      when "Integer"
        "Integer:#{value}" if value.bit_length <= MAX_BYTES
      when "Float", "NilClass", "TrueClass", "FalseClass"
        "#{value.class}:#{value}"
      end
    end
  end
end
