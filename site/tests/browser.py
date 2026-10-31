"""Real-time headless Chrome checks. Harness pages report via GET /__result?<json>."""
import functools
import http.server
import json
import os
import pathlib
import queue
import shutil
import subprocess
import tempfile
import threading
import urllib.parse

SITE = pathlib.Path(__file__).resolve().parent.parent
CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "google-chrome", "chromium", "chromium-browser",
]


def find_chrome():
    for candidate in [os.environ.get("CHROME", "")] + CHROME_CANDIDATES:
        if candidate and (shutil.which(candidate) or os.access(candidate, os.X_OK)):
            return shutil.which(candidate) or candidate
    return None


class _Handler(http.server.SimpleHTTPRequestHandler):
    results = None

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/__result":
            return super().do_GET()
        self.results.put(json.loads(urllib.parse.unquote(parsed.query)))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


class _Server(http.server.ThreadingHTTPServer):
    # Default backlog (5) drops Chrome's parallel connections and fakes resource errors.
    request_queue_size = 128
    daemon_threads = True


def _serve(results):
    handler = functools.partial(type("H", (_Handler,), {"results": results}), directory=str(SITE))
    server = _Server(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def run_page(chrome, page, timeout):
    """Load one harness page in a fresh profile; return its reported JSON or raise."""
    results = queue.Queue()
    server = _serve(results)
    profile = tempfile.mkdtemp(prefix="site-check-")
    url = f"http://127.0.0.1:{server.server_address[1]}/tests/{page}"
    proc = subprocess.Popen(
        [chrome, "--headless=new", "--disable-gpu", f"--user-data-dir={profile}",
         "--window-size=1400,1000", "--remote-debugging-port=0", url],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        return results.get(timeout=timeout)
    except queue.Empty:
        raise TimeoutError(f"{page}: no result within {timeout}s") from None
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        server.shutdown()
        shutil.rmtree(profile, ignore_errors=True)


def run(pages):
    """pages: [(file, timeout)] → list of error strings and list of info lines."""
    chrome = find_chrome()
    if not chrome:
        return ["browser: Chrome/Chromium not found (set CHROME=<path>)"], []
    errors, info = [], []
    for page, timeout in pages:
        try:
            report = run_page(chrome, page, timeout)
        except TimeoutError as exc:
            errors.append(f"browser: {exc}")
            continue
        for check in report.get("checks", []):
            line = f"{page}: {'PASS' if check['ok'] else 'FAIL'} {check['name']}"
            if check.get("detail"):
                line += f" — {check['detail']}"
            (info if check["ok"] else errors).append(line)
    return errors, info
