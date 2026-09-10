# frozen_string_literal: true

require "test_helper"

class TestCapturePolicy < Minitest::Test
  include AndOneTestHelper

  SECRET = "sentinel_private_password"

  def detection(sql = "SELECT * FROM comments WHERE body = '#{SECRET}'", **)
    AndOne::Detection.new(queries: [sql] * 8, count: 8,
                          raw_caller_strings: ["/private/#{SECRET}/app/models/post.rb:10:in 'comments'"] * 30,
                          **)
  end

  def test_all_default_sinks_exclude_literals_and_absolute_prefixes
    det = detection
    AndOne.aggregate.record(det)
    outputs = [det.inspect, AndOne::Formatter.new.format([det]), AndOne::JsonFormatter.new.format([det]),
               AndOne.aggregate.summary, File.read(File.join(@aggregate_tmpdir, "aggregate.json")),
               AndOne::DevUI.new(nil).call("PATH_INFO" => "/__and_one", "REMOTE_ADDR" => "::1").last.join]
    %i[text json].each do |format|
      path = File.join(@aggregate_tmpdir, "#{format}.log")
      writer = AndOne::LogfileWriter.new(path: path, format: format)
      writer.record([det])
      writer.flush!
      outputs << File.read(path)
      assert_equal 0, File.stat(path).mode & 0o077
    end
    outputs.each { |output| refute_includes output, SECRET }
    %w[aggregate.json aggregate.lock].each do |name|
      assert_equal 0, File.stat(File.join(@aggregate_tmpdir, name)).mode & 0o077
    end
  end

  def test_dialects_comments_and_unterminated_tokens
    ["'#{SECRET}'", "E'#{SECRET}'", "$$#{SECRET}$$", "$tag$#{SECRET}$tag$",
     "'#{SECRET}", "/*+ #{SECRET} */ 42", "/*! #{SECRET} */ 42",
     "42 -- #{SECRET}", "42 /* #{SECRET} */", "'prefix\\'#{SECRET}'"].each do |literal|
      refute_includes detection("SELECT * FROM comments WHERE body = #{literal}").sample_query, SECRET
    end
    [nil, "sqlite3", "mysql2"].each do |adapter|
      refute_includes detection("SELECT * FROM comments WHERE body = \"#{SECRET}\"", adapter: adapter).sample_query, SECRET
    end
    refute_includes detection("SELECT * FROM comments WHERE body = 42 # #{SECRET}", adapter: "mysql2").sample_query, SECRET
  end

  def test_session_dependent_backslash_quotes_fail_closed
    [nil, "sqlite3", "postgresql", "mysql2"].each do |adapter|
      ["'prefix\\' AND body = '#{SECRET}'", "'prefix\\'#{SECRET}'"].each do |value|
        refute_includes detection("SELECT * FROM comments WHERE body = #{value}", adapter: adapter).sample_query, SECRET
      end
    end
  end

  def test_detector_never_retains_bind_values_or_literal_samples
    detector = AndOne::Detector.new
    3.times do
      detector.record(sql: "SELECT * FROM comments WHERE body = '#{SECRET}' AND post_id = ?",
                      binds: [SECRET], type_casted_binds: -> { raise "must not evaluate binds" })
    end
    refute_includes detector.instance_variable_get(:@groups).inspect, SECRET
    assert_equal 3, detector.finish.first.count
    refute_includes detector.detections.inspect, SECRET
  end

  def test_limits_apply_to_direct_detections_and_raw_opt_in
    %i[redacted raw].each do |mode|
      AndOne.capture_mode = mode
      det = detection("SELECT * FROM comments #{"x" * 10_000}")
      assert_equal 5, det.queries.size
      assert_operator det.sample_query.bytesize, :<=, 2048
      assert_operator det.raw_caller_strings.size, :<=, 20
      assert(det.raw_caller_strings.all? { |frame| frame.bytesize <= 256 })
    end
    assert_includes detection.sample_query, SECRET
    assert_includes detection.raw_caller_strings.first, SECRET
    assert_raises(ArgumentError) { AndOne.capture_mode = :oops }
  ensure
    AndOne.capture_mode = :redacted
  end

  def test_legacy_raw_aggregate_is_redacted_on_read
    AndOne.capture_mode = :raw
    AndOne.aggregate.record(detection)
    AndOne.capture_mode = :redacted
    refute_includes AndOne.aggregate.detections.inspect, SECRET
    refute_includes File.read(File.join(@aggregate_tmpdir, "aggregate.json")), SECRET
  end

  def test_ignores_see_original_values_and_full_callers_before_capture
    path = File.join(@aggregate_tmpdir, "ignore")
    File.write(path, "query:#{SECRET}\n")
    detector = AndOne::Detector.new(ignore_list: AndOne::IgnoreFile.new(path))
    8.times { |i| detector.record(sql: "SELECT * FROM comments WHERE body = '#{i == 7 ? SECRET : "ordinary"}'") }
    assert_empty detector.finish

    AndOne.ignore_callers = [%r{/private/#{SECRET}/}]
    detector = AndOne::Detector.new
    frames = [AndOne::CapturePolicy::Location.new("/private/#{SECRET}/app/models/post.rb:10")]
    detector.stub(:caller_locations, frames) do
      3.times { detector.record(sql: "SELECT * FROM comments WHERE post_id = 1") }
    end
    assert_empty detector.finish
  end

  def test_raw_mode_remains_html_escaped
    AndOne.capture_mode = :raw
    AndOne.aggregate.record(detection("SELECT * FROM comments WHERE body = '<script>alert(1)</script>'"))
    html = AndOne::DevUI.new(nil).call("PATH_INFO" => "/__and_one", "REMOTE_ADDR" => "127.0.0.1").last.join
    refute_includes html, "<script>"
    assert_includes html, "&lt;script&gt;"
  ensure
    AndOne.capture_mode = :redacted
  end

  def test_dashboard_guard_defaults_and_override
    ui = AndOne::DevUI.new(nil)
    [nil, "192.0.2.1", "localhost"].each do |address|
      status, headers, body = ui.call("PATH_INFO" => "/__and_one", "REMOTE_ADDR" => address,
                                      "HTTP_X_FORWARDED_FOR" => "127.0.0.1")
      assert_equal 403, status
      assert_equal "no-store", headers["cache-control"]
      assert_equal ["Forbidden"], body
    end
    %w[127.0.0.1 ::1].each do |address|
      assert_equal 200, ui.call("PATH_INFO" => "/__and_one", "REMOTE_ADDR" => address).first
    end
    AndOne.dashboard_access_guard = ->(env) { env["trusted.user"] == "developer" }
    assert_equal 403, ui.call("PATH_INFO" => "/__and_one", "REMOTE_ADDR" => "127.0.0.1").first
    assert_equal 200, ui.call("PATH_INFO" => "/__and_one", "trusted.user" => "developer").first
    AndOne.dashboard_access_guard = ->(_env) { raise "guard failed" }
    assert_equal 403, ui.call("PATH_INFO" => "/__and_one").first
  ensure
    AndOne.dashboard_access_guard = nil
  end
end
