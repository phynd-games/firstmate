"""MkDocs hooks that keep the Firstmate document reader read-only and inert.

bin/fm-docs-reader.sh generates a private MkDocs configuration whose docs_dir is
one Firstmate home's data/ directory and points MkDocs at this file. The hooks
narrow what that site may contain and what a rendered page may do:

- on_files keeps only Markdown pages and a small allowlist of raster images
  whose real path is inside the real data/ directory with no symlink in any
  component, so a symlinked page cannot pull content from outside the home
  and no other private file (reports' raw payloads, JSON, HTML, patches) is
  ever copied into the served site. It also supplies a generated home page
  when data/ has no index.md or README.md, so the site root never 404s
  without writing anything into data/.
- on_page_content sanitizes every rendered page body with nh3 (ammonia): script
  and style elements, event-handler attributes, javascript: and data: URLs, and
  remote image sources are removed, while heading ids, permalink anchors, table
  structure, and syntax-highlight classes survive. Report text is data to be
  displayed, never code to run or a reason to reach the network.

The reader never executes MDX, meta modules, or any code found under data/.
The hooks must stay dependency-light: MkDocs, nh3, and Pygments are the whole
pinned runtime (defaults/docs-reader-requirements.txt).
"""

from __future__ import annotations

import os

import nh3
from mkdocs.structure.files import File, Files

IMAGE_EXTENSIONS = {".gif", ".jpeg", ".jpg", ".png", ".webp"}
HOME_PAGE_NAMES = ("index.md", "README.md")
GENERATED_HOME = (
    "# Firstmate documents\n\n"
    "This reader serves the Markdown under this home's `data/` directory.\n"
    "Use the navigation to open a document; pages update as files change.\n"
)


def _real_root(config) -> str:
    return os.path.realpath(config["docs_dir"])


def _inside_without_symlinks(real_root: str, src_path: str) -> bool:
    """True when every component of src_path under the root is a real entry."""
    current = real_root
    for part in src_path.replace(os.sep, "/").split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            return False
        current = os.path.join(current, part)
        if os.path.islink(current):
            return False
    real = os.path.realpath(current)
    return real == current and real.startswith(real_root + os.sep)


def _keep(real_root: str, file: File) -> bool:
    if file.abs_src_path is None:
        return True  # a generated page, never read from disk
    if os.path.realpath(file.src_dir) != real_root:
        return True  # a theme or override asset, not something read from data/
    extension = os.path.splitext(file.src_uri)[1].lower()
    if extension != ".md" and extension not in IMAGE_EXTENSIONS:
        return False
    return _inside_without_symlinks(real_root, file.src_path)


def on_files(files: Files, config) -> Files:
    real_root = _real_root(config)
    kept = [file for file in files if _keep(real_root, file)]
    if not any(file.src_uri in HOME_PAGE_NAMES for file in kept):
        kept.append(File.generated(config, "index.md", content=GENERATED_HOME))
    return Files(kept)


# Attribute policy: nh3's defaults plus the ids and classes MkDocs' toc
# permalinks, code highlighting, and tables rely on. Style attributes stay
# forbidden, as do every on* handler and every URL scheme not in nh3's list.
ALLOWED_ATTRIBUTES = {tag: set(attrs) for tag, attrs in nh3.ALLOWED_ATTRIBUTES.items()}
ALLOWED_ATTRIBUTES.setdefault("*", set()).update({"class", "id"})
ALLOWED_ATTRIBUTES.setdefault("a", set()).update({"title"})
ALLOWED_ATTRIBUTES.setdefault("img", set()).update({"title"})
ALLOWED_ATTRIBUTES.setdefault("abbr", set()).update({"title"})


def _attribute_filter(tag: str, attribute: str, value: str):
    """Drop image sources that would leave the home: private pages must not
    fetch anything remote or decode inline data URLs while rendering."""
    if tag == "img" and attribute == "src":
        candidate = value.strip().lower()
        if "://" in candidate or candidate.startswith(("//", "data:")):
            return None
    return value


def sanitize(html: str) -> str:
    return nh3.clean(
        html,
        attributes=ALLOWED_ATTRIBUTES,
        attribute_filter=_attribute_filter,
        link_rel="noopener noreferrer",
    )


def on_page_content(html: str, page, config, files) -> str:
    return sanitize(html)
