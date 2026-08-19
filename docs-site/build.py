#!/usr/bin/env python3
"""
Assemble the MkDocs source tree from the repository's Markdown.

The Markdown in docs/ is written to work on GitHub: chapters link to each other by
filename, and 83 links point at the templates they discuss — ../infra/modules/edge/
application-gateway.bicep and the like. Those source links cannot resolve on a published
site, because infra/ is not served there at all.

The wrong fix is to change the docs to suit the site, which would break them in the
repository and in every editor. This script does the opposite: it copies the Markdown into
site-src/ and rewrites only what has to change on the way out.

    docs/05-edge-waf.md          copied to  site-src/05-edge-waf.md
    README.md                    copied to  site-src/index.md
    ../infra/modules/…​.bicep      becomes    https://github.com/…/blob/main/infra/modules/…
    docs/02-network.md#24-…      becomes    02-network.md#24-…            (from the README)
    ../README.md                 becomes    index.md

Nothing under docs/ is modified. Run it, then `mkdocs build --strict`.
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = REPO_ROOT / "docs"
OUT_DIR = REPO_ROOT / "site-src"
ASSETS_SRC = Path(__file__).resolve().parent / "extra.css"

BLOB_BASE = "https://github.com/ozmvege/azure-bicep-lab/blob/main/"

# [text](target) — target stops at whitespace or the closing paren.
LINK = re.compile(r"(\[[^\]]*\]\()([^)\s]+)(\))")


def rewrite_target(target: str, source_file: Path) -> str:
    """Map one repo-relative link onto its published equivalent."""
    if target.startswith(("http://", "https://", "mailto:", "#")):
        return target

    path_part, _, fragment = target.partition("#")
    fragment = f"#{fragment}" if fragment else ""

    if not path_part:                       # a bare #anchor on the current page
        return target

    resolved = (source_file.parent / path_part).resolve()

    try:
        relative = resolved.relative_to(REPO_ROOT)
    except ValueError:                      # somehow outside the repository
        return target

    if relative == Path("README.md"):
        return f"index.md{fragment}"

    # A chapter linking to another chapter: both land flat in site-src/, so the filename
    # alone is correct and MkDocs can validate it.
    if relative.parts[0] == "docs" and relative.suffix == ".md":
        return f"{relative.name}{fragment}"

    # Everything else is source code, a workflow or a script — served by GitHub, not here.
    return BLOB_BASE + relative.as_posix() + fragment


def rewrite(markdown: str, source_file: Path) -> str:
    return LINK.sub(
        lambda m: m.group(1) + rewrite_target(m.group(2), source_file) + m.group(3),
        markdown,
    )


def main() -> int:
    if not DOCS_DIR.is_dir():
        print(f"error: {DOCS_DIR} not found — run this from the repository", file=sys.stderr)
        return 1

    if OUT_DIR.exists():
        shutil.rmtree(OUT_DIR)
    (OUT_DIR / "assets").mkdir(parents=True)

    written = 0

    readme = REPO_ROOT / "README.md"
    (OUT_DIR / "index.md").write_text(
        rewrite(readme.read_text(encoding="utf-8"), readme),
        encoding="utf-8",
    )
    written += 1

    for chapter in sorted(DOCS_DIR.glob("*.md")):
        (OUT_DIR / chapter.name).write_text(
            rewrite(chapter.read_text(encoding="utf-8"), chapter),
            encoding="utf-8",
        )
        written += 1

    shutil.copy2(ASSETS_SRC, OUT_DIR / "assets" / "extra.css")

    print(f"assembled {written} pages into {OUT_DIR.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
