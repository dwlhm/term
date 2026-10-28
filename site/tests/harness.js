// Shared helpers for browser harness pages: load index.html in an iframe, capture load-time
// errors from the very first frame, collect named checks, and report them to the check server.
window.Harness = (() => {
  const checks = [];
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  function check(name, ok, detail = '') {
    checks.push({ name, ok: Boolean(ok), detail: String(detail) });
  }

  function report() {
    fetch('/__result?' + encodeURIComponent(JSON.stringify({ checks })));
  }

  function load(frame, width, height = 900) {
    const errors = [];
    frame.style.cssText = `width:${width}px;height:${height}px;border:0;display:block`;
    const hook = setInterval(() => {
      const win = frame.contentWindow;
      if (!win || win.__hooked) return;
      win.__hooked = true;
      win.addEventListener('error', (event) => {
        const target = event.target && (event.target.src || event.target.href);
        errors.push(event.message || `failed to load ${target}`);
      }, true);
      win.addEventListener('unhandledrejection', (event) => errors.push(`rejection: ${event.reason}`));
    }, 1);
    return new Promise((resolve) => {
      frame.addEventListener('load', async () => {
        clearInterval(hook);
        await wait(400);
        resolve({ win: frame.contentWindow, doc: frame.contentDocument, errors });
      }, { once: true });
      frame.src = '../index.html';
    });
  }

  async function run(body) {
    try {
      await body();
    } catch (error) {
      check('harness completed', false, error && error.stack ? error.stack.split('\n')[0] : error);
    }
    report();
  }

  return { check, load, run, wait };
})();
