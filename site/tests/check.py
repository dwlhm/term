#!/usr/bin/env python3
"""Gate for site/: static contract lint + real-time headless browser checks.

  python3 site/tests/check.py                       # everything
  python3 site/tests/check.py --lint styles/hero.css  # lint only these files (relative to CWD or site/)
  python3 site/tests/check.py --browser layout      # only the layout page (layout | game)
"""
import argparse
import sys

sys.dont_write_bytecode = True

import browser  # noqa: E402
import lint  # noqa: E402

PAGES = {"layout": ("layout.html", 60), "game": ("game.html", 90)}


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lint", nargs="*", metavar="FILE", help="lint only these files")
    parser.add_argument("--browser", nargs="*", choices=sorted(PAGES), help="browser pages to run")
    parser.add_argument("-v", "--verbose", action="store_true", help="print passing checks too")
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    run_all = args.lint is None and args.browser is None
    errors, info = [], []
    if run_all or args.lint is not None:
        errors += lint.run(args.lint)
    if run_all or args.browser is not None:
        names = args.browser or sorted(PAGES)
        browser_errors, browser_info = browser.run([PAGES[name] for name in names])
        errors += browser_errors
        info += browser_info
    for line in info if args.verbose else []:
        print(line)
    for line in errors:
        print(f"FAIL {line}")
    print(f"{'FAILED' if errors else 'OK'}: {len(errors)} failure(s), {len(info)} passing browser check(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
