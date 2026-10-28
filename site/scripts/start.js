(() => {
  "use strict";

  const RESET_DELAY = 1500;
  const DEFAULT_LABEL = "Copy";
  const timers = new WeakMap();

  function getCommand(button) {
    const block = button.closest(".start-code");
    const code = block ? block.querySelector("code") : null;
    return code ? code.textContent.trim() : "";
  }

  async function writeClipboard(text) {
    if (!text) return false;
    if (!navigator.clipboard || typeof navigator.clipboard.writeText !== "function") return false;
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      return false;
    }
  }

  function announce(button, label, state) {
    button.textContent = label;
    button.dataset.state = state;
    const block = button.closest(".start-code");
    const status = block ? block.querySelector(".start-status") : null;
    if (status) {
      status.textContent = state === "copied" ? "Copied to clipboard" : state === "error" ? "Copy failed" : "";
    }
  }

  function resetLater(button) {
    const pending = timers.get(button);
    if (pending) clearTimeout(pending);
    timers.set(
      button,
      setTimeout(() => announce(button, DEFAULT_LABEL, "idle"), RESET_DELAY),
    );
  }

  function bind(button) {
    button.addEventListener("click", async () => {
      const copied = await writeClipboard(getCommand(button));
      announce(button, copied ? "Copied" : "Copy failed", copied ? "copied" : "error");
      resetLater(button);
    });
  }

  function init() {
    document.querySelectorAll(".start-copy").forEach(bind);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
