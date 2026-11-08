"""Book library: scan the library folder, give each book a stable id (content
hash), and assemble the listing the iOS app browses.

book_id == sha256 of the PDF or TXT bytes. It is stable across renames/moves, so the
pre-clean cache, the audio cache and the listening position all key off it.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Optional

from . import config
from .db import DB

# Rough spoken characters per second — only used to show an estimated runtime
# in the library before a book has been generated. ~14 c/s ≈ 165 wpm.
SPEECH_CHARS_PER_S = 14.0

# (path, mtime, size) -> hash, so re-listing the folder doesn't re-hash files.
_HASH_CACHE: dict[tuple[str, float, int], str] = {}
# hash -> last known path, so resolve_pdf is O(1) instead of rescanning 300 PDFs.
_PATH_BY_HASH: dict[str, Path] = {}


def file_hash(path: str | Path) -> str:
    p = Path(path)
    st = p.stat()
    key = (str(p), st.st_mtime, st.st_size)
    cached = _HASH_CACHE.get(key)
    if cached:
        _PATH_BY_HASH[cached] = p
        return cached
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    digest = h.hexdigest()
    _HASH_CACHE[key] = digest
    _PATH_BY_HASH[digest] = p
    return digest


def _preclean_meta(pdf_hash: str) -> Optional[dict]:
    meta_file = config.preclean_dir() / pdf_hash / "meta.json"
    if not meta_file.exists():
        return None
    try:
        return json.loads(meta_file.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def _est_duration_s(pdf_hash: str) -> Optional[float]:
    plan = config.preclean_dir() / pdf_hash / "chunks.json"
    if not plan.exists():
        return None
    try:
        chunks = json.loads(plan.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    chars = sum(len(c[0]) for c in chunks if c and c[0])
    return chars / SPEECH_CHARS_PER_S if chars else None


def cache_status(db: DB, pdf_hash: str, voice_id: Optional[int],
                 fmt: str) -> str:
    """none | cleaned | partial | ready for a given voice/format."""
    if voice_id is not None:
        row = db.get_cache(f"{pdf_hash}:{voice_id}:{fmt}")
        if row:
            return row["state"]  # partial | ready
    if (config.preclean_dir() / pdf_hash / "chunks.json").exists():
        return "cleaned"
    return "none"


def _all_books() -> list[Path]:
    """Every book (PDF or TXT) anywhere under the library folder (recursive), sorted."""
    return sorted(config.library_dir().rglob("*.pdf")) + sorted(config.library_dir().rglob("*.txt"))


def _book_cover_path(pdf: Path, pdf_hash: str) -> Optional[Path]:
    """Find cover image for a book.

    booksOUT structure: <Series>/covers/<title>.jpg  (title = pdf stem)
    The covers/ folder is a sibling of the TXT file, not a sibling of the series folder.

    Also handles the older structure where covers live next to books.
    Falls back to the preclean cache.
    """
    books_out = config.books_out_dir()
    lib_dir = config.library_dir()

    # 1. booksOUT: <lib>/Series/covers/<title>.jpg
    if books_out.exists() and pdf.exists():
        try:
            rel = pdf.relative_to(lib_dir)
        except ValueError:
            rel = None
        if rel:
            series_parent = rel.parent
            cover = books_out / series_parent / "covers" / f"{pdf.stem}.jpg"
            if cover.exists():
                return cover

    # 2. Older structure: covers/ folder next to the book file itself
    sibling_cover = pdf.with_name("covers") / f"{pdf.stem}.jpg"
    if sibling_cover.exists():
        return sibling_cover
    sibling_cover2 = pdf.parent / "covers" / f"{pdf.stem}.jpg"
    if sibling_cover2.exists():
        return sibling_cover2

    # 3. preclean cache: <hash>/cover.jpg
    preclean_cover = config.preclean_dir() / pdf_hash / "cover.jpg"
    if preclean_cover.exists():
        return preclean_cover
    return None


def _book_dict(db: DB, pdf: Path, voice_id: Optional[int], fmt: str) -> dict:
    h = file_hash(pdf)
    meta = _preclean_meta(h) or {}
    prog = db.get_progress(h)
    rel = pdf.relative_to(config.library_dir())
    cover_path = _book_cover_path(pdf, h)
    book_voice = db.get_book_voice(h)
    return {
        "book_id": h,
        "filename": pdf.name,
        "rel_path": rel.as_posix(),
        "folder": rel.parent.as_posix() if rel.parent.as_posix() != "." else "",
        "title": pdf.stem,
        "author": meta.get("author") or "",
        "series": meta.get("series"),
        "has_cover": cover_path is not None,
        "est_duration_s": _est_duration_s(h),
        "cache_status": cache_status(db, h, voice_id, fmt),
        "position_s": prog["position_s"] if prog else 0.0,
        "voice_id": book_voice,
    }


def list_books(db: DB, voice_id: Optional[int] = None,
               fmt: str = "m4b") -> list[dict]:
    """Flat list of every book in the library (recursive)."""
    out = []
    for pdf in _all_books():
        try:
            out.append(_book_dict(db, pdf, voice_id, fmt))
        except OSError:
            continue
    return out


def browse(db: DB, folder: str = "", q: Optional[str] = None,
           voice_id: Optional[int] = None, fmt: str = "m4b") -> dict:
    """Folder browser + global search.

    With `q`: a flat search across ALL books (title/author/filename/path).
    Otherwise: the contents of `folder` — its immediate subfolders (with a
    recursive book count) and the books directly inside it.
    """
    pdfs = _all_books()
    if q:
        ql = q.lower()
        books = []
        for pdf in pdfs:
            try:
                b = _book_dict(db, pdf, voice_id, fmt)
            except OSError:
                continue
            hay = f"{b['title']} {b['author']} {b['rel_path']}".lower()
            if ql in hay:
                books.append(b)
        return {"folder": "", "query": q, "subfolders": [], "books": books}

    folder = folder.strip("/")
    subcounts: dict[str, int] = {}
    books = []
    for pdf in pdfs:
        rel = pdf.relative_to(config.library_dir()).as_posix()
        if folder:
            if not rel.startswith(folder + "/"):
                continue
            remainder = rel[len(folder) + 1:]
        else:
            remainder = rel
        if "/" in remainder:                       # lives in a subfolder
            sub = remainder.split("/", 1)[0]
            subcounts[sub] = subcounts.get(sub, 0) + 1
        else:                                       # a book directly here
            try:
                books.append(_book_dict(db, pdf, voice_id, fmt))
            except OSError:
                continue
    subfolders = [
        {"name": name,
         "path": f"{folder}/{name}" if folder else name,
         "count": cnt}
        for name, cnt in sorted(subcounts.items())
    ]
    return {"folder": folder, "query": None,
            "subfolders": subfolders, "books": books}


def started_books(db: DB, voice_id: Optional[int] = None,
                  fmt: str = "m4b") -> list[dict]:
    """Books with a saved listening position ("Continue listening"), most
    recently played first.

    Books whose PDF is temporarily missing are still returned as ghost entries
    (pdf_missing=True) so they stay visible in the UI instead of silently
    disappearing. The stored title/author from the progress row are used as
    fallback metadata."""
    rows = db.query(
        "SELECT * FROM progress WHERE position_s > 1 ORDER BY updated_at DESC")
    out = []
    for r in rows:
        pdf = resolve_pdf(r["book_id"])
        if not pdf:
            # Keep the book visible even though the PDF is not currently found.
            # title/author were saved by put_progress; fall back to a short hash.
            out.append({
                "book_id": r["book_id"],
                "filename": "",
                "rel_path": "",
                "folder": "",
                "title": r.get("title") or r["book_id"][:12] + "…",
                "author": r.get("author") or "",
                "series": None,
                "has_cover": False,
                "est_duration_s": r.get("duration_s"),
                "cache_status": "none",
                "position_s": r["position_s"],
                "duration_s": r.get("duration_s"),
                "updated_at": r["updated_at"],
                "pdf_missing": True,
            })
            continue
        try:
            b = _book_dict(db, pdf, voice_id, fmt)
        except OSError:
            continue
        b["duration_s"] = r["duration_s"]
        b["updated_at"] = r["updated_at"]
        b["pdf_missing"] = False
        out.append(b)
    return out


def resolve_pdf(pdf_hash: str) -> Optional[Path]:
    """Map a book_id back to a book file (PDF or TXT) in the library folder.

    Three-tier strategy:
      1. in-memory cache (validates hash before returning)
      2. library scan using mtime/size hash cache to avoid re-hashing unchanged files
      3. booksOUT fallback: source file not in library but processed TXT exists in booksOUT
    """
    # Tier 1: cached path still valid?
    cached = _PATH_BY_HASH.get(pdf_hash)
    if cached and cached.exists():
        try:
            if file_hash(cached) == pdf_hash:
                return cached
        except OSError:
            pass

    # Tier 2: library scan
    for pdf in _all_books():
        try:
            if file_hash(pdf) == pdf_hash:
                return pdf
        except OSError:
            continue

    # Tier 3: booksOUT fallback — source file is in booksIN but processed TXT is in booksOUT
    books_out = config.books_out_dir()
    if books_out.exists():
        for txt in books_out.rglob("*.txt"):
            try:
                st = txt.stat()
            except OSError:
                continue
            key = (str(txt), st.st_mtime, st.st_size)
            known = _HASH_CACHE.get(key)
            if known is None:
                try:
                    if file_hash(txt) == pdf_hash:
                        _PATH_BY_HASH[pdf_hash] = txt
                        return txt
                except OSError:
                    continue
    return None


def ensure_cover(pdf_hash: str) -> Optional[Path]:
    """Lazily extract a book's cover on first request.
    Checks booksOUT/covers/ first, then falls back to preclean extraction."""
    # booksOUT cover?
    pdf = resolve_pdf(pdf_hash)
    if pdf:
        cover = _book_cover_path(pdf, pdf_hash)
        if cover:
            return cover
    # preclean fallback
    cdir = config.preclean_dir() / pdf_hash
    jpg = cdir / "cover.jpg"
    if jpg.exists():
        return jpg
    if not pdf:
        return None
    try:
        from .pdfproc.extract import extract_cover
        cdir.mkdir(parents=True, exist_ok=True)
        png = extract_cover(str(pdf), cdir)
        if png and Path(png).exists():
            import shutil
            shutil.copyfile(png, jpg)
            return jpg
    except Exception:  # noqa: BLE001
        return None
    return None
