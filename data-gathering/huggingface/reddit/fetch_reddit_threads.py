#!/usr/bin/env python3
"""
fetch_reddit_threads.py
=======================
Downloads public Reddit data from Hugging Face datasets and saves it as
plain-text files inside a zip archive.

No Reddit API credentials are required — all data is sourced from
pre-collected, publicly available Hugging Face datasets.

PURPOSE
-------
Generates bulk text data suitable for testing AI summarisation pipelines,
token throughput, context window limits, and multi-participant conversation
handling in the CaseWeave application.

OUTPUT FORMAT
-------------
Each post or comment batch is saved as one .txt file inside the zip,
organised by dataset subfolder:

    <output_zip>/
        pushshift/ps_00001_some_post_title.txt
        reddit_tb/tb_00001_another_title.txt
        jokes/jk_00001_a_classic_joke.txt
        confessions/co_00001_a_confession.txt
        hf_comments/hc_00001_explainlikeimfive.txt
        reddit_clean/rc_00001_summarisation_pair.txt
        ...

DATASETS (verified working, standard Parquet format)
-----------------------------------------------------
KEY             HF NAME                                     CONTENT TYPE
pushshift       fddemarco/pushshift-reddit                  posts — author/date/subreddit/score
reddit_tb       sentence-transformers/reddit-title-body     posts — title/body/subreddit
jokes           SocialGrep/one-million-reddit-jokes         comments — r/Jokes
confessions     SocialGrep/one-million-reddit-confessions   posts — r/confession + similar
questions       SocialGrep/one-million-reddit-questions     posts — question subreddits
answers         SocialGrep/ten-million-reddit-answers       comments — answer threads
crypto          SocialGrep/reddit-crypto-aug-2021           comments — r/CryptoCurrency
wsb             SocialGrep/reddit-wallstreetbets-aug-2021   comments — r/wallstreetbets
covid           SocialGrep/the-reddit-covid-dataset         comments — r/Coronavirus
hf_comments     HuggingFaceGECLM/REDDIT_comments            comments — named subreddit splits
reddit_clean    SophieTr/reddit_clean                       content+summary pairs

REQUIREMENTS
------------
    pip install datasets huggingface_hub

USAGE
-----
    # List all datasets with status
    python fetch_reddit_threads.py --list

    # Search Hugging Face Hub for more Reddit datasets
    python fetch_reddit_threads.py --search reddit

    # Fetch default verified datasets up to 250 MB
    python fetch_reddit_threads.py --mb 250 --out /path/to/output.zip

    # Fetch specific datasets by key
    python fetch_reddit_threads.py --datasets pushshift confessions --mb 100

OPTIONS
-------
    --mb        Target uncompressed size in MB (default: 250)
    --out       Output zip path (default: ./reddit_threads.zip)
    --datasets  Space-separated dataset keys (default: all verified)
    --list      Print dataset table and exit
    --search    Search HF Hub by keyword and exit
"""

import argparse
import os
import re
import zipfile
from datetime import datetime, timezone


# ─── DEFAULTS ──────────────────────────────────────────────────────────────────
DEFAULT_TARGET_MB = 250
DEFAULT_OUTPUT    = os.path.join(os.path.dirname(__file__), "reddit_threads.zip")

# Registry of datasets.
# split:  single split name, OR list of split names (all will be streamed in order)
# status: 'verified' | 'broken'
KNOWN_DATASETS = [
    # ── Post datasets (have title + body) ──────────────────────────────────────
    {
        "key":         "pushshift",
        "hf_name":     "fddemarco/pushshift-reddit",
        "split":       "train",
        "description": "Pushshift Reddit posts — rich metadata",
        "content":     "author, subreddit, UTC timestamp, score, num_comments, title, selftext",
        "approx_mb":   420,
        "status":      "verified",
        "zip_folder":  "pushshift",
        "fmt_type":    "pushshift",
    },
    {
        "key":         "reddit_tb",
        "hf_name":     "sentence-transformers/reddit-title-body",
        "split":       "train",
        "description": "Reddit posts — title, body, subreddit",
        "content":     "title, body, subreddit (no author/date)",
        "approx_mb":   300,
        "status":      "verified",
        "zip_folder":  "reddit_tb",
        "fmt_type":    "reddit_tb",
    },
    {
        "key":         "confessions",
        "hf_name":     "SocialGrep/one-million-reddit-confessions",
        "split":       "train",
        "description": "1M Reddit confession posts",
        "content":     "author, subreddit, title, selftext, created_utc, score, num_comments",
        "approx_mb":   None,
        "status":      "verified",
        "zip_folder":  "confessions",
        "fmt_type":    "sg_post",
    },
    {
        "key":         "questions",
        "hf_name":     "SocialGrep/one-million-reddit-questions",
        "split":       "train",
        "description": "1M Reddit question posts",
        "content":     "author, subreddit, title, selftext, created_utc, score, num_comments",
        "approx_mb":   None,
        "status":      "verified",
        "zip_folder":  "questions",
        "fmt_type":    "sg_post",
    },
    # ── Comment datasets (body only, no title) ─────────────────────────────────
    {
        "key":         "jokes",
        "hf_name":     "SocialGrep/one-million-reddit-jokes",
        "split":       "train",
        "description": "1M Reddit joke comments (r/Jokes)",
        "content":     "author, subreddit, body, created_utc, score, parent_id",
        "approx_mb":   300,
        "status":      "verified",
        "zip_folder":  "jokes",
        "fmt_type":    "sg_comment",
    },
    {
        "key":         "answers",
        "hf_name":     "SocialGrep/ten-million-reddit-answers",
        "split":       "train",
        "description": "10M Reddit answer comments across many subreddits",
        "content":     "author, subreddit, body, created_utc, score, parent_id",
        "approx_mb":   None,
        "status":      "verified",
        "zip_folder":  "answers",
        "fmt_type":    "sg_comment",
    },
    {
        "key":         "crypto",
        "hf_name":     "SocialGrep/reddit-crypto-aug-2021",
        "split":       "train",
        "description": "Reddit crypto comments — Aug 2021 snapshot",
        "content":     "author, subreddit, body, created_utc, score, parent_id",
        "approx_mb":   None,
        "status":      "verified",
        "zip_folder":  "crypto",
        "fmt_type":    "sg_comment",
    },
    {
        "key":         "wsb",
        "hf_name":     "SocialGrep/reddit-wallstreetbets-aug-2021",
        "split":       "train",
        "description": "Reddit WallStreetBets comments — Aug 2021 snapshot",
        "content":     "author, subreddit, body, created_utc, score, parent_id",
        "approx_mb":   None,
        "status":      "verified",
        "zip_folder":  "wsb",
        "fmt_type":    "sg_comment",
    },
    {
        "key":         "covid",
        "hf_name":     "SocialGrep/the-reddit-covid-dataset",
        "split":       "train",
        "description": "Reddit COVID comments (r/Coronavirus)",
        "content":     "author, subreddit, body, created_utc, score, parent_id",
        "approx_mb":   None,
        "status":      "verified",
        "zip_folder":  "covid",
        "fmt_type":    "sg_comment",
    },
    {
        "key":         "hf_comments",
        "hf_name":     "HuggingFaceGECLM/REDDIT_comments",
        # splits are subreddit names — load a curated selection
        "split":       ["programming", "explainlikeimfive", "changemyview",
                        "LifeProTips", "WritingPrompts", "tifu",
                        "todayilearned", "science", "askscience", "ifyoulikeblank"],
        "description": "Reddit comments — 10 curated subreddit splits",
        "content":     "author, subreddit, body, created_utc, score, link_id, parent_id",
        "approx_mb":   None,
        "status":      "verified",
        "zip_folder":  "hf_comments",
        "fmt_type":    "sg_comment",
    },
    # ── Summarisation pair dataset ─────────────────────────────────────────────
    {
        "key":         "reddit_clean",
        "hf_name":     "SophieTr/reddit_clean",
        "split":       "train",
        "description": "Reddit posts paired with human summaries",
        "content":     "content (long post), summary (short human-written summary)",
        "approx_mb":   None,
        "status":      "verified",
        "zip_folder":  "reddit_clean",
        "fmt_type":    "reddit_clean",
    },
    # ── Broken (old loading scripts, kept for reference) ───────────────────────
    {
        "key":         "tifu",
        "hf_name":     "reddit_tifu",
        "split":       "train",
        "description": "Reddit TIFU posts with TLDRs (BROKEN)",
        "content":     "title, long body, tldr, score",
        "approx_mb":   120,
        "status":      "broken",
        "zip_folder":  "tifu",
        "fmt_type":    None,
    },
    {
        "key":         "tldr17",
        "hf_name":     "webis/tldr-17",
        "split":       "train",
        "description": "Reddit posts with TLDR summaries — Webis (BROKEN)",
        "content":     "title, body, tldr, subreddit",
        "approx_mb":   None,
        "status":      "broken",
        "zip_folder":  "tldr17",
        "fmt_type":    None,
    },
]
# ───────────────────────────────────────────────────────────────────────────────


# ─── HELPERS ───────────────────────────────────────────────────────────────────

def safe_filename(title: str, idx: int, prefix: str = "") -> str:
    slug = re.sub(r"[^\w\s-]", "", (title or "untitled").lower())
    slug = re.sub(r"[\s_-]+", "_", slug).strip("_")[:60]
    p = f"{prefix}_" if prefix else ""
    return f"{p}{idx:05d}_{slug}.txt"


def utc_str(ts) -> str:
    """Handle both Unix int timestamps and datetime strings."""
    if ts is None:
        return "unknown"
    try:
        return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    except (ValueError, TypeError):
        return str(ts)   # already a formatted string


# ─── FORMATTERS ────────────────────────────────────────────────────────────────

def fmt_pushshift(record: dict, idx: int) -> tuple[str, str]:
    """fddemarco/pushshift-reddit — posts with full metadata."""
    lines = [
        f"DATASET:     pushshift-reddit",
        f"POST ID:     {record.get('id', idx)}",
        f"SUBREDDIT:   r/{record.get('subreddit', 'unknown')}",
        f"AUTHOR:      u/{record.get('author', '[deleted]')}",
        f"POSTED:      {utc_str(record.get('created_utc', 0))}",
        f"SCORE:       {record.get('score', '')}",
        f"COMMENTS:    {record.get('num_comments', '')}",
        "",
        "─── TITLE ──────────────────────────────────────────────────────────────────",
        record.get("title", "").strip(),
    ]
    body = (record.get("selftext") or "").strip()
    if body and body not in ("[removed]", "[deleted]"):
        lines += ["", "─── POST ───────────────────────────────────────────────────────────────────", body]
    title = record.get("title", f"post_{idx}")
    return "\n".join(lines), title


def fmt_reddit_tb(record: dict, idx: int) -> tuple[str, str]:
    """sentence-transformers/reddit-title-body — title + body."""
    lines = [
        f"DATASET:     reddit-title-body",
        f"SUBREDDIT:   r/{record.get('subreddit', 'unknown')}",
        "",
        "─── TITLE ──────────────────────────────────────────────────────────────────",
        record.get("title", "").strip(),
    ]
    body = (record.get("body") or "").strip()
    if body:
        lines += ["", "─── POST ───────────────────────────────────────────────────────────────────", body]
    return "\n".join(lines), record.get("title", f"post_{idx}")


def fmt_sg_post(record: dict, idx: int) -> tuple[str, str]:
    """SocialGrep post datasets — confessions, questions (have title + selftext)."""
    lines = [
        f"DATASET:     {record.get('subreddit', 'unknown')}",
        f"POST ID:     {record.get('id', idx)}",
        f"SUBREDDIT:   r/{record.get('subreddit', 'unknown')}",
        f"AUTHOR:      u/{record.get('author', '[deleted]')}",
        f"POSTED:      {utc_str(record.get('created_utc'))}",
        f"SCORE:       {record.get('score', '')}",
        f"COMMENTS:    {record.get('num_comments', '')}",
        "",
        "─── TITLE ──────────────────────────────────────────────────────────────────",
        record.get("title", "").strip(),
    ]
    body = (record.get("selftext") or "").strip()
    if body and body not in ("[removed]", "[deleted]"):
        lines += ["", "─── POST ───────────────────────────────────────────────────────────────────", body]
    return "\n".join(lines), record.get("title", f"post_{idx}")


def fmt_sg_comment(record: dict, idx: int) -> tuple[str, str]:
    """SocialGrep comment datasets — body only (jokes, answers, crypto, wsb, covid, hf_comments)."""
    body = (record.get("body") or "").strip()
    lines = [
        f"DATASET:     {record.get('subreddit', 'unknown')}",
        f"COMMENT ID:  {record.get('id', idx)}",
        f"SUBREDDIT:   r/{record.get('subreddit', 'unknown')}",
        f"AUTHOR:      u/{record.get('author', '[deleted]')}",
        f"POSTED:      {utc_str(record.get('created_utc'))}",
        f"SCORE:       {record.get('score', '')}",
        f"PARENT:      {record.get('parent_id', '')}",
        "",
        "─── COMMENT ────────────────────────────────────────────────────────────────",
        body,
    ]
    title = f"comment_{idx}_{record.get('subreddit', 'unknown')}"
    return "\n".join(lines), title


def fmt_reddit_clean(record: dict, idx: int) -> tuple[str, str]:
    """SophieTr/reddit_clean — long content + human-written summary pairs."""
    lines = [
        f"DATASET:     reddit_clean (summarisation pairs)",
        f"RECORD ID:   {idx:05d}",
        "",
        "─── CONTENT ────────────────────────────────────────────────────────────────",
        (record.get("content") or "").strip(),
        "",
        "─── HUMAN SUMMARY ──────────────────────────────────────────────────────────",
        (record.get("summary") or "").strip(),
    ]
    return "\n".join(lines), f"summary_pair_{idx}"


FORMATTERS = {
    "pushshift":    (fmt_pushshift,    lambda r: (
        (r.get("selftext") or "").strip() in ("", "[removed]", "[deleted]")
        and len(r.get("title", "")) < 60
    )),
    "reddit_tb":    (fmt_reddit_tb,    lambda r: not (r.get("body") or "").strip()),
    "sg_post":      (fmt_sg_post,      lambda r: not (r.get("title") or "").strip()),
    "sg_comment":   (fmt_sg_comment,   lambda r: not (r.get("body") or "").strip()),
    "reddit_clean": (fmt_reddit_clean, lambda r: not (r.get("content") or "").strip()),
}


# ─── COLLECTION ────────────────────────────────────────────────────────────────

def collect_dataset(ds_meta: dict, target_bytes: int, collected: list, total_bytes: list):
    """Stream records from a dataset (or multiple splits) until target_bytes reached."""
    from datasets import load_dataset

    key      = ds_meta["key"]
    hf_name  = ds_meta["hf_name"]
    folder   = ds_meta["zip_folder"]
    fmt_type = ds_meta["fmt_type"]
    splits   = ds_meta["split"]
    if isinstance(splits, str):
        splits = [splits]

    fmt_fn, skip_fn = FORMATTERS[fmt_type]
    prefix = key[:2]

    kept = 0
    for split_name in splits:
        if total_bytes[0] >= target_bytes:
            break
        print(f"  Loading {hf_name} / {split_name} ...")
        ds = load_dataset(hf_name, split=split_name, streaming=True)
        seen = 0
        for rec in ds:
            if total_bytes[0] >= target_bytes:
                break
            seen += 1
            if skip_fn(rec):
                continue
            text, title = fmt_fn(rec, kept)
            fname = safe_filename(title, kept, prefix)
            collected.append((f"{folder}/{fname}", text))
            total_bytes[0] += len(text.encode("utf-8"))
            kept += 1
            if kept % 10000 == 0:
                print(f"    {key}: {kept:,} kept / {seen:,} seen — {total_bytes[0]/1024/1024:.1f} MB")

    print(f"  {key} done: {kept:,} records — {total_bytes[0]/1024/1024:.1f} MB total")


# ─── LIST / SEARCH ─────────────────────────────────────────────────────────────

def cmd_list():
    sym = {"verified": "✓", "broken": "✗"}
    print()
    print(f"{'KEY':<14} {'':2} {'HF DATASET':<48} {'SIZE':<9} DESCRIPTION")
    print("─" * 105)
    for d in KNOWN_DATASETS:
        s    = sym.get(d["status"], "?")
        size = f"~{d['approx_mb']} MB" if d["approx_mb"] else "unknown"
        note = "" if d["status"] == "verified" else f"  [{d['status']}]"
        print(f"{d['key']:<14} {s}  {d['hf_name']:<48} {size:<9} {d['description']}{note}")
        print(f"{'':16}   {'':48} {'':9} {d['content']}")
        print()
    print("Status:  ✓ verified working   ✗ broken (old loading script, unsupported)")
    print()
    print("Usage:   python fetch_reddit_threads.py --datasets KEY [KEY ...] --mb 100")
    print()


def cmd_search(keyword: str):
    try:
        from huggingface_hub import HfApi
    except ImportError:
        print("pip install huggingface_hub")
        return

    print(f"\nSearching Hugging Face for datasets matching '{keyword}' ...\n")
    api     = HfApi()
    results = list(api.list_datasets(search=keyword, limit=40))
    if not results:
        print("No results found.")
        return

    known_names = {d["hf_name"] for d in KNOWN_DATASETS}
    print(f"{'DATASET':<52} {'DOWNLOADS':<12} TAGS")
    print("─" * 95)
    for ds in results:
        dl_str = f"{ds.downloads:,}" if getattr(ds, "downloads", None) else "n/a"
        tags   = ", ".join((ds.tags or [])[:4])
        marker = "  [in registry]" if ds.id in known_names else ""
        print(f"{ds.id:<52} {dl_str:<12} {tags}{marker}")
    print(f"\n{len(results)} results.")
    print("To add a dataset: edit KNOWN_DATASETS and add a matching entry to FORMATTERS.")
    print()


# ─── MAIN ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Download Reddit data from Hugging Face and save to zip.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--list",     action="store_true", help="Print dataset table and exit")
    parser.add_argument("--search",   type=str, metavar="KEYWORD", help="Search HF Hub by keyword")
    parser.add_argument("--mb",       type=int, default=DEFAULT_TARGET_MB,
                        help=f"Target uncompressed MB (default: {DEFAULT_TARGET_MB})")
    parser.add_argument("--out",      type=str, default=DEFAULT_OUTPUT,
                        help=f"Output zip path (default: {DEFAULT_OUTPUT})")
    parser.add_argument("--datasets", type=str, nargs="+", metavar="KEY",
                        help="Dataset keys to use (see --list). Default: all verified")
    args = parser.parse_args()

    if args.list:
        cmd_list()
        return

    if args.search:
        cmd_search(args.search)
        return

    verified_keys = [d["key"] for d in KNOWN_DATASETS if d["status"] == "verified"]
    requested     = args.datasets or verified_keys
    unknown       = [k for k in requested if k not in {d["key"] for d in KNOWN_DATASETS}]
    if unknown:
        print(f"Unknown dataset key(s): {unknown}. Run --list to see valid keys.")
        return

    selected = [d for d in KNOWN_DATASETS
                if d["key"] in requested and d["status"] == "verified" and d["fmt_type"]]

    target_bytes = args.mb * 1024 * 1024
    out_path     = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    print(f"Target:   {args.mb} MB uncompressed")
    print(f"Datasets: {[d['key'] for d in selected]}")
    print(f"Output:   {out_path}")
    print()

    collected   = []
    total_bytes = [0]

    for ds_meta in selected:
        if total_bytes[0] >= target_bytes:
            break
        print(f"[{ds_meta['key']}] {ds_meta['description']}")
        collect_dataset(ds_meta, target_bytes, collected, total_bytes)
        print()

    print(f"Writing {len(collected):,} files ({total_bytes[0]/1024/1024:.1f} MB) to zip ...")
    with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for fname, text in collected:
            zf.writestr(fname, text.encode("utf-8"))

    zip_size = os.path.getsize(out_path)
    print(f"\nDone.")
    print(f"  Files:        {len(collected):,}")
    print(f"  Uncompressed: {total_bytes[0]/1024/1024:.1f} MB")
    print(f"  Zip size:     {zip_size/1024/1024:.1f} MB")
    print(f"  Location:     {out_path}")


if __name__ == "__main__":
    main()
