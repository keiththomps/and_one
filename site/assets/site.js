"use strict";

// Everything else works without JavaScript. Reveal copy controls only when ready.
for (const button of document.querySelectorAll("[data-copy]")) {
  button.hidden = false;
  button.addEventListener("click", async () => {
    const snippet = document.getElementById(button.dataset.copy);
    const status = document.querySelector(".copy-status");
    try {
      await navigator.clipboard.writeText(snippet.textContent);
      status.textContent = "Copied. Add it to your Gemfile, then run bundle install.";
    } catch {
      // Local HTTP or denied clipboard permissions: select for manual copying.
      const range = document.createRange();
      range.selectNodeContents(snippet);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      status.textContent = "Snippet selected. Press Ctrl+C (or ⌘C) to copy.";
    }
  });
}
