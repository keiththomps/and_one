# frozen_string_literal: true

module AndOne
  # Bounded lifecycle metadata normalization for Aggregate's store transactions.
  # Uses the aggregate's UTF-8 bounding and timestamp parsing helpers.
  module AggregateLifecycle
    private

    def reopen_entry!(entry, reason)
      entry["status"] = "open"
      entry["reopened_at"] = Time.now.iso8601(6)
      entry["reopen_reason"] = reason
    end

    def lifecycle(entry)
      status = entry.fetch("status", "open")
      raise IOError, "Invalid issue status" unless %w[open resolved].include?(status)

      resolution = entry["resolution"]
      if resolution
        raise IOError, "Invalid resolution" unless resolution.is_a?(Hash) && resolution["note"].is_a?(String) &&
                                                   resolution["occurrences_at_resolution"].is_a?(Integer) &&
                                                   resolution["occurrences_at_resolution"].positive? && resolution["resolved_at"]

        resolution = { "resolved_at" => parse_time(resolution["resolved_at"]).iso8601(6),
                       "note" => bounded(resolution["note"], 2048),
                       "revision" => resolution["revision"] && bounded(resolution["revision"], 128),
                       "occurrences_at_resolution" => resolution["occurrences_at_resolution"] }
      end
      raise IOError, "Missing resolution" if status == "resolved" && !resolution
      raise IOError, "Invalid reopen reason" unless [nil, "manual", "observed"].include?(entry["reopen_reason"])

      { "status" => status, "resolution" => resolution,
        "reopened_at" => parse_time(entry["reopened_at"])&.iso8601(6), "reopen_reason" => entry["reopen_reason"] }
    end
  end
end
