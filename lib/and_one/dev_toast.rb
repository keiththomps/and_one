# frozen_string_literal: true

module AndOne
  # Injects a small toast notification into HTML responses when N+1 queries
  # are detected during the request. Links to the DevUI dashboard for details.
  #
  # Activated automatically by the Railtie in development when `dev_toast` is on,
  # or can be enabled manually:
  #   AndOne.dev_toast = true
  #
  # The toast appears as a fixed-position badge and auto-dismisses after
  # 8 seconds (click to keep open).
  #
  # Position is configurable via `AndOne.dev_toast_position`:
  #   :top_right (default), :top_left, :bottom_right, :bottom_left
  module DevToast
    POSITIONS = {
      top_right: { vertical: "top", horizontal: "right", slide_from: "-1rem" },
      top_left: { vertical: "top", horizontal: "left", slide_from: "-1rem" },
      bottom_right: { vertical: "bottom", horizontal: "right", slide_from: "1rem" },
      bottom_left: { vertical: "bottom", horizontal: "left", slide_from: "1rem" }
    }.freeze

    module_function

    # Injects toast HTML/JS/CSS before </body> in an HTML response.
    # Returns the modified body string, or the original if not injectable.
    def inject(body_string, detections)
      return body_string if detections.nil? || detections.empty?
      return body_string unless body_string.include?("</body>")

      toast_html = render_toast(detections)
      body_string.sub("</body>", "#{toast_html}\n</body>")
    end

    def render_toast(detections)
      count = detections.size
      label = "N+1 quer#{count == 1 ? "y" : "ies"}"

      summaries = detections.map do |d|
        table = escape(d.table_name || "unknown")
        "#{d.count}x <code>#{table}</code>"
      end.first(5)

      extra = count > 5 ? "<div class=\"and-one-toast-extra\">...and #{count - 5} more</div>" : ""
      pos = POSITIONS[AndOne.dev_toast_position || :top_right] || POSITIONS[:top_right]

      <<~HTML
        <div id="and-one-toast" class="and-one-toast" role="status" aria-live="polite">
          <div class="and-one-toast-header">
            <span class="and-one-toast-icon">🏀</span>
            <strong>AndOne:</strong> #{count} #{label} detected
            <button class="and-one-toast-close" onclick="document.getElementById('and-one-toast').remove()" aria-label="Dismiss">&times;</button>
          </div>
          <div class="and-one-toast-body">
            #{summaries.join("<br>")}
            #{extra}
          </div>
          <a class="and-one-toast-link" href="#{DevUI::MOUNT_PATH}">View Dashboard →</a>
        </div>
        <style>
          .and-one-toast {
            position: fixed;
            #{pos[:vertical]}: 1rem;
            #{pos[:horizontal]}: 1rem;
            z-index: 999999;
            background: #1a1a2e;
            color: #e0e0e0;
            border: 2px solid #ff6b6b;
            border-radius: 8px;
            padding: 0;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace;
            font-size: 13px;
            max-width: 380px;
            min-width: 260px;
            box-shadow: 0 4px 24px rgba(0,0,0,0.4);
            animation: and-one-slide-in 0.3s ease-out;
            transition: opacity 0.3s ease;
          }
          .and-one-toast-header {
            display: flex;
            align-items: center;
            gap: 0.4rem;
            padding: 0.5rem 0.75rem;
            background: #16213e;
            border-radius: 6px 6px 0 0;
            border-bottom: 1px solid #2a2a4a;
            color: #ff6b6b;
            font-size: 13px;
          }
          .and-one-toast-icon { font-size: 16px; }
          .and-one-toast-close {
            margin-left: auto;
            background: none;
            border: none;
            color: #888;
            font-size: 18px;
            cursor: pointer;
            padding: 0 0.25rem;
            line-height: 1;
          }
          .and-one-toast-close:hover { color: #ff6b6b; }
          .and-one-toast-body {
            padding: 0.5rem 0.75rem;
            line-height: 1.5;
            color: #ccc;
          }
          .and-one-toast-body code {
            background: #16213e;
            padding: 0.1rem 0.3rem;
            border-radius: 3px;
            font-size: 12px;
            color: #ffd93d;
          }
          .and-one-toast-extra {
            color: #888;
            font-size: 12px;
            margin-top: 0.25rem;
          }
          .and-one-toast-link {
            display: block;
            padding: 0.5rem 0.75rem;
            color: #a8d8ea;
            text-decoration: none;
            font-size: 12px;
            border-top: 1px solid #2a2a4a;
          }
          .and-one-toast-link:hover {
            background: #16213e;
            border-radius: 0 0 6px 6px;
            text-decoration: underline;
          }
          @keyframes and-one-slide-in {
            from { transform: translateY(#{pos[:slide_from]}); opacity: 0; }
            to   { transform: translateY(0);                   opacity: 1; }
          }
        </style>
        <script>
          (function() {
            var toast = document.getElementById('and-one-toast');
            if (!toast) return;
            var timer = setTimeout(function() {
              toast.style.opacity = '0';
              setTimeout(function() { toast.remove(); }, 300);
            }, 8000);
            toast.addEventListener('mouseenter', function() { clearTimeout(timer); });
          })();
        </script>
      HTML
    end

    def escape(text)
      text.to_s
          .gsub("&", "&amp;")
          .gsub("<", "&lt;")
          .gsub(">", "&gt;")
          .gsub('"', "&quot;")
    end
  end
end
