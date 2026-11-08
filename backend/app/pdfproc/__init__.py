"""PDF -> clean chunk plan + metadata + cover.

Heavy imports (fitz/PyMuPDF) stay inside prepare_job so that the pure-stdlib
parts (cleaning/chunking/metadata parsing) are importable everywhere,
including the test sandbox.
"""
from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

from .chunking import split_into_chunks
from .cleaning import clean_text
from .metadata import parse_filename, resolve_metadata, write_id3

__all__ = ["prepare_job", "prepare_or_load", "prepare_txt", "clean_text", "split_into_chunks",
           "parse_filename", "resolve_metadata", "write_id3"]

# Bump when extraction/front-matter logic changes. Cached plans whose metadata
# carries an older version are rebuilt automatically on next access.
EXTRACTION_VERSION = 3


def _announce_heading(title: str, text: str) -> str:
    """Detach a heading that got glued to sentence one and re-announce it as
    its own paragraph: 'PROLOGUE The feeling...' -> 'Prologue.\\n\\nThe feeling...'
    so TTS speaks the title, pauses, then starts the prose."""
    pat = re.compile(r"^\s*" + re.escape(title) + r"[\s.:,;-]*", re.I)
    body = pat.sub("", text, count=1).lstrip()
    sep = "" if title.rstrip()[-1:] in ".!?" else "."
    return f"{title}{sep}\n\n{body}" if body else f"{title}{sep}"


def prepare_job(pdf_path: str, work_dir: Path,
                skip_front_matter: bool = True) -> dict:
    """Extract, clean, chunk (chapter-aware) and gather metadata/cover.

    Returns chunks as (text, para_end, chapter_idx) plus chapter_titles —
    chapter boundaries come from the PDF's embedded TOC when present.
    """
    from .chapters import build_chapters, detect_story_start
    from .extract import (extract_cover, extract_pages_with_report, get_toc,
                          pdf_metadata)
    meta = resolve_metadata(pdf_path, pdf_metadata(pdf_path))
    pages, extraction_report = extract_pages_with_report(pdf_path)
    toc = get_toc(pdf_path)
    story = None
    if skip_front_matter and not toc:
        story = detect_story_start(pages)
        extraction_report.update(story)
    else:
        extraction_report.update({
            "story_start_page": 1,
            "confidence": 1.0 if toc else 0.0,
            "reason": "TOC-based front-matter handling" if toc
                      else "front-matter skipping disabled",
            "skipped_pages": [],
        })
    chapters = build_chapters(pages, toc,
                              fallback_title=meta["title"],
                              skip_front_matter=skip_front_matter,
                              story_start_page=(story or {}).get("story_start_page"))
    multi = len(chapters) > 1  # only announce headings for real, multi-chapter TOCs

    chunks: list[tuple[str, bool, int]] = []
    titles: list[str] = []
    debug_text: list[str] = []
    for text_raw in chapters:
        title, raw = text_raw
        text = clean_text(raw)
        if not text:
            continue
        if multi:
            text = _announce_heading(title, text)
        ci = len(titles)
        titles.append(title)
        debug_text.append(f"=== {title}\n{text}")
        for t, para in split_into_chunks(text):
            chunks.append((t, para, ci))
    if not chunks:
        raise RuntimeError("TXT contains no text after cleaning")
    cover = extract_cover(pdf_path, work_dir)
    (work_dir / "clean_text.txt").write_text("\n\n".join(debug_text),
                                             encoding="utf-8")
    (work_dir / "extraction_report.json").write_text(
        json.dumps(extraction_report, indent=2, ensure_ascii=False),
        encoding="utf-8")
    return {**meta, "cover_path": cover, "chunks": chunks,
            "chapter_titles": titles,
            "extraction_report": extraction_report}


def prepare_txt(txt_path: str) -> dict:
    """Read a plain TXT file, clean it, chunk it, and gather metadata.

    Returns the same dict shape as prepare_job: chunks as 3-tuples
    (text, para_end, chapter_idx), chapter_titles=["Full Text"].
    No cover is extracted for TXT files.
    """
    from .metadata import parse_filename, split_series

    path = Path(txt_path)
    parent_author = path.parent.name if path.parent.name not in (".", "") else ""
    author = parent_author

    track, name_title = parse_filename(path.stem)
    series, title = split_series(name_title)

    try:
        text_raw = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        # Fall back to latin-1 for files with Windows-1252 or similar chars
        text_raw = path.read_text(encoding="latin-1")
    text = clean_text(text_raw)
    if not text:
        raise RuntimeError("TXT contains no text after cleaning")

    raw_chunks = split_into_chunks(text)
    chunks: list[tuple[str, bool, int]] = [
        (t, para, 0) for t, para in raw_chunks
    ]

    extraction_report = {
        "source": "txt",
        "file_size_bytes": path.stat().st_size,
        "char_count": len(text),
        "chunk_count": len(chunks),
        "chapter_count": 1,
        "author_from_folder": bool(parent_author),
    }

    return {
        "title": title,
        "author": author,
        "track": track,
        "series": series,
        "cover_path": None,
        "chunks": chunks,
        "chapter_titles": ["Full Text"],
        "extraction_report": extraction_report,
    }


def prepare_or_load(pdf_path: str, pdf_hash: str, *,
                    skip_front_matter: bool = True) -> dict:
    """Pre-clean cache: run prepare_job (PDF) or prepare_txt (TXT) once per book
    (keyed by content hash) and reuse the result on later conversions and for
    library listing.

    The cleaning/chunking step is cheap next to TTS, but caching it gives the
    library instant metadata/cover and lets a conversion start without re-parsing.
    Returns the same dict shape as prepare_job (chunks as lists, not tuples).
    """
    from . import __name__ as _pkg  # noqa: F401 (keep heavy imports lazy)
    from .. import config

    is_txt = pdf_path.lower().endswith(".txt")

    cache = config.preclean_dir() / pdf_hash
    plan_file = cache / "chunks.json"
    meta_file = cache / "meta.json"
    if plan_file.exists() and meta_file.exists():
        meta = json.loads(meta_file.read_text(encoding="utf-8"))
        cache_valid = (
            meta.get("extraction_version") == EXTRACTION_VERSION
            and bool(meta.get("skip_front_matter", True)) == bool(skip_front_matter)
        )
        if cache_valid:
            chunks = json.loads(plan_file.read_text(encoding="utf-8"))
            cover = cache / "cover.jpg"
            return {**meta, "chunks": chunks,
                    "cover_path": str(cover) if cover.exists() else None}

    cache.mkdir(parents=True, exist_ok=True)
    cover_out = None

    if is_txt:
        result = prepare_txt(pdf_path)
    else:
        result = prepare_job(pdf_path, cache, skip_front_matter=skip_front_matter)
        # Normalize cover into the cache dir under a stable name.
        if result.get("cover_path") and Path(result["cover_path"]).exists():
            cover_out = cache / "cover.jpg"
            if Path(result["cover_path"]) != cover_out:
                shutil.copyfile(result["cover_path"], cover_out)

    meta = {k: result[k] for k in
            ("title", "author", "track", "series", "chapter_titles",
             "extraction_report")}
    meta["extraction_version"] = EXTRACTION_VERSION
    meta["skip_front_matter"] = bool(skip_front_matter)
    plan_file.write_text(json.dumps(result["chunks"]), encoding="utf-8")
    meta_file.write_text(json.dumps(meta), encoding="utf-8")
    # Return the JSON-canonical (list) form so the cache-miss and cache-hit
    # paths are identical for callers.
    chunks = json.loads(plan_file.read_text(encoding="utf-8"))
    return {**meta, "chunks": chunks,
            "cover_path": str(cover_out) if cover_out else None}
