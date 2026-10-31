"""Static contract checks from site/DESIGN.md (tokens only, class prefixes, size limits)."""
import pathlib
import re

SITE = pathlib.Path(__file__).resolve().parent.parent
MAX_LINES = 250
PREFIX = {
    "hero.css": "hero-", "start.css": "start-", "footer.css": "foot-",
    "features.css": "feat-", "game.css": "game-",
}
SHARED_CLASSES = {
    "container", "section", "section-head", "eyebrow", "section-title",
    "section-lede", "visually-hidden",
}
RAW_COLOR = re.compile(r"#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?)\(")
CLASS_SELECTOR = re.compile(r"\.([a-zA-Z][\w-]*)")
MARKERS = re.compile(r"\b(" + "|".join(["TO" "DO", "FIX" "ME", "X" "XX"]) + r")\b")


def _strip_comments(css):
    return re.sub(r"/\*.*?\*/", "", css, flags=re.S)


def _selectors(css):
    """Yield selector text only (skip declaration blocks and at-rule preludes)."""
    for match in re.finditer(r"([^{}]+)\{", _strip_comments(css)):
        text = match.group(1).strip()
        if not text.startswith("@"):
            yield text


def check_css(path):
    errors = []
    css = path.read_text()
    if path.name != "tokens.css":
        for n, line in enumerate(_strip_comments(css).splitlines(), 1):
            if RAW_COLOR.search(line):
                errors.append(f"{path.name}:{n}: raw color, use a token: {line.strip()}")
    prefix = PREFIX.get(path.name)
    if prefix:
        for selector in _selectors(css):
            for cls in CLASS_SELECTOR.findall(selector):
                if not cls.startswith(prefix) and cls not in SHARED_CLASSES:
                    errors.append(f"{path.name}: class .{cls} lacks prefix '{prefix}'")
    return errors


def _display(path):
    return str(path.relative_to(SITE)) if path.is_relative_to(SITE) else str(path)


def check_file(path):
    errors = []
    text = path.read_text()
    lines = text.count("\n") + 1
    if path.suffix in {".css", ".js", ".py"} and lines > MAX_LINES:
        errors.append(f"{_display(path)}: {lines} lines > {MAX_LINES}")
    for n, line in enumerate(text.splitlines(), 1):
        if MARKERS.search(line):
            errors.append(f"{_display(path)}:{n}: leftover marker")
    if path.suffix == ".css":
        errors += check_css(path)
    return errors


def default_files():
    globs = ["styles/*.css", "scripts/**/*.js", "tests/*.py", "index.html"]
    return sorted({p for g in globs for p in SITE.glob(g)})


def _resolve(name):
    """Accept paths relative to the CWD (e.g. repo root) or to site/."""
    path = pathlib.Path(name)
    if path.is_absolute() or path.exists():
        return path.resolve()
    return SITE / path


def run(files=None):
    paths = [_resolve(f) for f in files or []]
    errors = []
    for path in paths or default_files():
        if not path.is_file():
            errors.append(f"{path}: missing")
            continue
        errors += check_file(path)
    return errors
