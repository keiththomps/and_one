# frozen_string_literal: true

require "digest"
require "json"

module AndOne
  # Attribute events without checking out Base's (possibly unrelated) connection.
  module ConnectionContext
    def self.metadata(payload)
      connection = payload[:connection]
      config = connection&.pool&.db_config
      return { connection_adapter: "unknown", connection_id: nil } unless config

      settings = config.configuration_hash
      # Never retain credentials or the full connection URL. The digest is stable
      # across connections/workers for the same configured database and role.
      identity = [config.env_name, config.name, config.adapter,
                  settings[:host], settings[:port], settings[:database],
                  connection.pool.respond_to?(:role) ? connection.pool.role : nil,
                  connection.pool.respond_to?(:shard) ? connection.pool.shard : nil]
      { connection_adapter: config.adapter, connection_id: Digest::SHA256.hexdigest(JSON.generate(identity)) }
    rescue StandardError
      { connection_adapter: "unknown", connection_id: nil }
    end
  end
end
