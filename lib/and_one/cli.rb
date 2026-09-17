# frozen_string_literal: true

require "optparse"
require "json"
require "time"
require_relative "../and_one"
require_relative "skill_installer"

module AndOne
  # Offline inspection and explicit issue lifecycle transitions. Never boots the app.
  class CLI
    class Error < StandardError
      attr_reader :code, :status

      def initialize(code, message, status = 2)
        super(message)
        @code = code
        @status = status
      end
    end

    # Aggregate normalization operates on this private snapshot, never the file.
    class Snapshot
      def initialize(path)
        input = File.open(path, "rb") { |file| file.read(AggregateStore::FileStore::MAX_BYTES + 1) }
        raise IOError, "Aggregate exceeds byte limit" if input.bytesize > AggregateStore::FileStore::MAX_BYTES

        @data = JSON.parse(input)
        raise IOError, "Invalid aggregate document" unless @data.is_a?(Hash)
      end

      def transaction
        yield @data
      end
    end

    def self.run(argv = ARGV, out: $stdout, err: $stderr)
      new(out: out, err: err).run(argv)
    end

    def initialize(out:, err:)
      @out = out
      @err = err
    end

    def run(argv)
      args = argv.dup
      @options = { json: args.include?("--json"), root: Dir.pwd, environment: ENV.fetch("RAILS_ENV", "development"),
                   session: ENV.fetch("AND_ONE_SESSION", "default"), sort: "time", target: "agents" }
      parser = option_parser
      parser.parse!(args)
      return @out.puts(parser) || 0 if @options[:help]

      command = args.shift
      payload = case command
                when "issues" then findings(args, status: @options[:status] || "open")
                when "export" then findings(args, status: @options[:status] || "all")
                when "show" then show(args)
                when "resolve", "reopen" then transition(command, args)
                when "sessions" then sessions(args)
                when "skill" then skill(args)
                else raise Error.new("usage", "Expected issues, show/resolve/reopen ISSUE_ID, export, sessions, or skill install/check")
                end
      emit(payload)
      0
    rescue Error => e
      failure(e.code, e.message, e.status)
    rescue OptionParser::ParseError => e
      failure("usage", e.message, 2)
    rescue StandardError => e
      # Do not leak malformed stored documents or filesystem exception details.
      failure("storage_error", "Unable to read or update AndOne data (#{e.class})", 2)
    end

    private

    def option_parser
      OptionParser.new do |parser|
        parser.banner = "Usage: and-one issues|show/resolve/reopen ISSUE_ID|export|sessions|skill install/check [options]"
        parser.on("--json", "Emit schema-versioned JSON") { @options[:json] = true }
        parser.on("--root PATH", "Application root (default: current directory)") { |v| @options[:root] = File.expand_path(v) }
        parser.on("--environment NAME", "Default: RAILS_ENV or development") { |v| @options[:environment] = v }
        parser.on("--session ID", "Default: AND_ONE_SESSION or default; select test runs explicitly") { |v| @options[:session] = v }
        parser.on("--path DIRECTORY", "Explicit aggregate directory; overrides session selection") { |v| @options[:path] = File.expand_path(v) }
        parser.on("--sort FIELD", %w[time queries occurrences], "time, queries, or occurrences") { |v| @options[:sort] = v }
        parser.on("--status STATUS", %w[open resolved all], "Filter issues/export; issues defaults to open, export to all") { |v| @options[:status] = v }
        parser.on("--note TEXT", "Required verification note for resolve (max 2,048 bytes retained)") { |v| @options[:note] = v }
        parser.on("--revision REVISION", "Optional revision associated with the fix") { |v| @options[:revision] = v }
        parser.on("--target NAME", %w[agents pi claude], "Skill destination: agents (default), pi, claude") { |v| @options[:target] = v }
        parser.on("--force", "Replace a modified installed skill") { @options[:force] = true }
        parser.on("-h", "--help") { @options[:help] = true }
      end
    end

    def sessions_root
      File.join(@options[:root], "tmp/and_one/sessions")
    end

    def aggregate_path
      @options[:path] || Session.new(root: sessions_root, environment: @options[:environment], id: @options[:session]).path
    end

    def no_args!(args)
      raise Error.new("usage", "Unexpected arguments") unless args.empty?
    end

    def findings(args, status: "all")
      no_args!(args)
      path = aggregate_path
      file = File.join(path, "aggregate.json")
      snapshot = begin
        Snapshot.new(file)
      rescue Errno::ENOENT
        raise Error.new("missing_session", "No persisted aggregate; enable file storage and reproduce a finding", 3)
      end
      entries = Aggregate.new(store: snapshot, strict: true).detections
      rows = JSON.parse(JsonFormatter.new.format_aggregate(entries))
      rows.select! { |row| row["status"] == status } unless status == "all"
      rows.sort_by! do |row|
        cost = row["cumulative_query_cost"]
        value = case @options[:sort]
                when "occurrences" then row["occurrences"]
                when "queries" then cost && cost["query_count"]
                else cost["total_duration_ms"] if cost && cost["timed_query_count"].positive?
                end
        [value.nil? ? 1 : 0, -(value || 0), row["issue_id"]]
      end
      finding_payload(rows, path)
    end

    def finding_payload(rows, path)
      { storage: { status: "ok", path: path },
        session: @options[:path] ? nil : { environment: @options[:environment], id: @options[:session] },
        application_booted: false, findings: rows }
    end

    def show(args)
      id = args.shift
      raise Error.new("usage", "show requires an issue_id") unless id

      payload = findings(args)
      payload[:findings].select! { |row| row["issue_id"] == id }
      raise Error.new("issue_not_found", "Issue not retained in selected session", 4) if payload[:findings].empty?

      payload
    end

    def transition(command, args)
      id = args.shift
      raise Error.new("usage", "#{command} requires an issue_id") unless id

      no_args!(args)
      raise Error.new("usage", "resolve requires --note describing verification") if command == "resolve" && @options[:note].to_s.strip.empty?

      store = AggregateStore::FileStore.new(aggregate_path, require_existing: true)
      aggregate = Aggregate.new(store: store, strict: true)
      entry = if command == "resolve"
                aggregate.resolve!(id, note: @options[:note], revision: @options[:revision])
              else
                aggregate.reopen!(id)
              end
      rows = JSON.parse(JsonFormatter.new.format_aggregate({ id => entry }))
      finding_payload(rows, aggregate_path)
    rescue Aggregate::IssueNotFound
      raise Error.new("issue_not_found", "Issue not retained in selected session", 4)
    rescue Errno::ENOENT
      raise Error.new("missing_session", "No persisted aggregate or lock file for the selected session", 3)
    end

    def sessions(args)
      no_args!(args)
      rows = session_keys.sort.filter_map do |key|
        next unless key.match?(/\A[0-9a-f]{64}\z/)

        file = File.join(sessions_root, key, "aggregate.json")
        begin
          stat = File.stat(file)
          next unless stat.file?

          { key: key, path: File.dirname(file), modified_at: stat.mtime.utc.iso8601 }
        rescue Errno::ENOENT
          next
        end
      end
      { sessions: rows }
    end

    def session_keys
      Dir.children(sessions_root)
    rescue Errno::ENOENT
      []
    end

    def skill(args)
      action = args.shift
      no_args!(args)
      installer = SkillInstaller.new(root: @options[:root], target: @options[:target])
      case action
      when "install" then installer.install(force: @options[:force])
      when "check" then installer.check
      else raise Error.new("usage", "Expected skill install or skill check")
      end
    end

    def emit(payload)
      envelope = { schema_version: 1, and_one_version: VERSION }.merge(payload)
      @out.puts(@options[:json] ? JSON.generate(envelope) : JSON.pretty_generate(envelope))
    end

    def failure(code, message, status)
      payload = { schema_version: 1, error: { code: code, message: message } }
      @err.puts(@options && @options[:json] ? JSON.generate(payload) : "and-one: #{message}")
      status
    end
  end
end
