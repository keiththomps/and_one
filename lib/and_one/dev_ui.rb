# frozen_string_literal: true

module AndOne
  # A tiny Rack endpoint that shows all N+1s detected in the current server
  # session. Mount at `/__and_one` in development to get a mini dashboard
  # for N+1 queries with fix suggestions.
  #
  # Requires `aggregate_mode = true` to collect detections across requests.
  #
  # Usage (manual):
  #   app.middleware.use AndOne::DevUI
  #
  # Or it's auto-mounted by the Railtie in development when aggregate_mode is on.
  class DevUI
    MOUNT_PATH = "/__and_one"

    def initialize(app)
      @app = app
    end

    def call(env)
      if env["PATH_INFO"] == MOUNT_PATH
        serve_dashboard(env)
      else
        @app.call(env)
      end
    end

    private

    def serve_dashboard(_env)
      entries = AndOne.aggregate_mode ? AndOne.aggregate.detections : {}

      html = render_html(entries)
      [200, { "content-type" => "text/html; charset=utf-8" }, [html]]
    end

    def render_html(entries)
      rows = if entries.empty?
               <<~HTML
                 <tr>
                   <td colspan="6" class="empty">
                     No N+1 queries detected yet.
                     #{"<br><strong>Tip:</strong> Set <code>AndOne.aggregate_mode = true</code> to collect detections across requests." unless AndOne.aggregate_mode}
                   </td>
                 </tr>
               HTML
             else
               entries.map.with_index do |(fp, entry), i|
                 det = entry.detection
                 suggestion = begin
                   AndOne::AssociationResolver.resolve(det, det.raw_caller_strings)
                 rescue StandardError
                   nil
                 end
                 fix = suggestion&.actionable? ? h(suggestion.fix_hint) : "—"
                 strict_hint = suggestion&.strict_loading_hint ? h(suggestion.strict_loading_hint) : ""
                 loading_hint = suggestion&.loading_strategy_hint ? h(suggestion.loading_strategy_hint) : ""

                 origin = det.origin_frame ? format_frame(det.origin_frame) : "—"
                 fix_loc = det.fix_location ? format_frame(det.fix_location) : "—"

                 <<~HTML
                   <tr>
                     <td>#{i + 1}</td>
                     <td><code>#{h(det.table_name || "unknown")}</code></td>
                     <td>#{entry.occurrences}</td>
                     <td><code class="sql">#{h(truncate(det.sample_query, 200))}</code></td>
                     <td>
                       <div class="origin">#{h(origin)}</div>
                       <div class="fix-loc">⇒ #{h(fix_loc)}</div>
                     </td>
                     <td>
                       <div class="suggestion">#{fix}</div>
                       #{"<div class=\"strategy\">#{loading_hint}</div>" unless loading_hint.empty?}
                       #{"<div class=\"strict\">#{strict_hint}</div>" unless strict_hint.empty?}
                       <div class="fingerprint">#{h(fp)}</div>
                     </td>
                   </tr>
                 HTML
               end.join
             end

      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>🏀 AndOne — N+1 Dashboard</title>
          <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace; background: #1a1a2e; color: #e0e0e0; padding: 2rem; }
            h1 { color: #ff6b6b; margin-bottom: 0.5rem; font-size: 1.5rem; }
            .subtitle { color: #888; margin-bottom: 1.5rem; font-size: 0.9rem; }
            table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
            th { background: #16213e; color: #ff6b6b; text-align: left; padding: 0.75rem; border-bottom: 2px solid #ff6b6b; }
            td { padding: 0.75rem; border-bottom: 1px solid #2a2a4a; vertical-align: top; }
            tr:hover { background: #16213e; }
            .empty { text-align: center; padding: 3rem; color: #666; font-size: 1.1rem; }
            code { background: #16213e; padding: 0.15rem 0.4rem; border-radius: 3px; font-size: 0.8rem; }
            code.sql { display: block; white-space: pre-wrap; word-break: break-all; color: #a8d8ea; }
            .origin { color: #ffd93d; }
            .fix-loc { color: #6bcb77; margin-top: 0.25rem; }
            .suggestion { color: #6bcb77; font-weight: bold; }
            .strategy { color: #a8d8ea; margin-top: 0.25rem; font-size: 0.8rem; }
            .strict { color: #888; margin-top: 0.25rem; font-size: 0.8rem; }
            .fingerprint { color: #555; font-family: monospace; margin-top: 0.25rem; font-size: 0.75rem; }
            .count-badge { background: #ff6b6b; color: white; padding: 0.2rem 0.5rem; border-radius: 10px; font-weight: bold; }
            .actions { margin-bottom: 1rem; }
            .actions a { color: #a8d8ea; text-decoration: none; margin-right: 1rem; }
            .actions a:hover { text-decoration: underline; }
          </style>
        </head>
        <body>
          <h1>🏀 AndOne — N+1 Dashboard</h1>
          <p class="subtitle">#{entries.size} unique N+1 pattern#{"s" if entries.size != 1} detected this session</p>
          <div class="actions">
            <a href="#{MOUNT_PATH}">↻ Refresh</a>
          </div>
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>Table</th>
                <th>Count</th>
                <th>Query</th>
                <th>Location</th>
                <th>Fix</th>
              </tr>
            </thead>
            <tbody>
              #{rows}
            </tbody>
          </table>
        </body>
        </html>
      HTML
    end

    def h(text)
      text.to_s
          .gsub("&", "&amp;")
          .gsub("<", "&lt;")
          .gsub(">", "&gt;")
          .gsub('"', "&quot;")
    end

    def truncate(text, max)
      return text if text.length <= max

      "#{text[0...max]}..."
    end

    def format_frame(frame)
      frame
        .sub(%r{.*/app/}, "app/")
        .sub(%r{.*/lib/}, "lib/")
        .sub(%r{.*/test/}, "test/")
        .sub(%r{.*/spec/}, "spec/")
    end
  end
end
