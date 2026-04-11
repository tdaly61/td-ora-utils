#!/usr/bin/env python3
"""
Summarise Reddit conversation .txt files using a local Ollama model.

Usage examples:
  # Assume ollama is already running, use default model
  python summarise_conversations.py /path/to/conversations

  # Start ollama server, use a specific model
  python summarise_conversations.py /path/to/conversations --model llama3.1:70b --start-ollama

  # Resume a previous run, skip corpus summary
  python summarise_conversations.py /path/to/conversations --resume --skip-corpus

  # Write outputs to a specific directory
  python summarise_conversations.py /path/to/conversations --output-dir ./results
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from tqdm import tqdm
import ollama

# System prompt for individual conversations
INDIVIDUAL_SYSTEM = """You are an expert social scientist analysing Reddit conversations.
Summarise each thread concisely but richly. Focus on:
- Main topics and sub-topics
- Key arguments and counter-arguments
- Participant perspectives and sentiment
- Notable quotes or turning points
- Any emergent patterns"""

# System prompt for the final corpus-level summary
CORPUS_SYSTEM = """You are an expert social scientist synthesising hundreds of Reddit conversations.
Produce a high-level research-grade summary of the ENTIRE corpus.
Identify:
- Overarching themes and how they evolve
- Dominant narratives vs minority views
- Sentiment trends
- Key controversies or consensus points
- Any surprising patterns or contradictions"""

MAX_CHARS = 120_000   # ~100k token safety margin per file
CORPUS_CHUNK_THRESHOLD = 110_000  # trigger intermediate chunking
CORPUS_CHUNK_SIZE = 20            # summaries per intermediate chunk


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarise Reddit conversation .txt files with a local Ollama model.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "directory",
        help="Directory containing unzipped .txt conversation files.",
    )
    parser.add_argument(
        "--model",
        default="gemma4:26b",
        help="Ollama model to use (default: gemma4:26b).",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Directory to write output files (default: same as input directory).",
    )
    parser.add_argument(
        "--start-ollama",
        action="store_true",
        help="Start `ollama serve` before running. Skip this flag if ollama is already running.",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="Resume a previous run: load existing per-file summaries and skip already-processed files.",
    )
    parser.add_argument(
        "--skip-corpus",
        action="store_true",
        help="Skip the final corpus-level summary (useful for very large datasets or quick tests).",
    )
    parser.add_argument(
        "--max-chars",
        type=int,
        default=MAX_CHARS,
        help=f"Maximum characters per file before truncation (default: {MAX_CHARS}).",
    )
    return parser.parse_args()


def start_ollama_server() -> subprocess.Popen:
    """Launch `ollama serve` as a background process and wait until it responds."""
    print("Starting ollama server...")
    proc = subprocess.Popen(
        ["ollama", "serve"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    # Poll until the server is ready (up to 30 s)
    for _ in range(30):
        try:
            ollama.list()
            print("  ollama server is ready.")
            return proc
        except Exception:
            time.sleep(1)
    proc.terminate()
    sys.exit("ERROR: ollama server did not become ready within 30 seconds.")


def ensure_model_pulled(model: str) -> None:
    """Pull the model if it is not already available locally."""
    local_models = {m["model"] for m in ollama.list().get("models", [])}
    if model not in local_models:
        print(f"Model '{model}' not found locally — pulling (this may take a while)...")
        ollama.pull(model)
        print(f"  '{model}' pulled successfully.")
    else:
        print(f"Model '{model}' is available locally.")



def summarize_text(text: str, system_prompt: str, model: str, max_chars: int) -> str:
    if not text.strip():
        return ""
    if len(text) > max_chars:
        text = text[:max_chars] + "\n...[truncated]"

    response = ollama.chat(
        model=model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": f"Summarise the following Reddit conversation(s):\n\n{text}"},
        ],
        options={"temperature": 0.0},  # deterministic for research
    )
    return response["message"]["content"].strip()


def load_existing_summaries(json_path: Path) -> dict:
    if json_path.exists():
        with open(json_path, encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_summaries(json_path: Path, summaries: dict) -> None:
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(summaries, f, indent=2, ensure_ascii=False)


def main() -> None:
    args = parse_args()

    input_dir = Path(args.directory).resolve()
    if not input_dir.is_dir():
        sys.exit(f"ERROR: '{input_dir}' is not a directory.")

    output_dir = Path(args.output_dir).resolve() if args.output_dir else input_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    # Timestamp suffix so repeated runs don't clobber each other
    run_ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    safe_model = args.model.replace(":", "-").replace("/", "-")
    json_path = output_dir / f"reddit_summaries_{safe_model}.json"
    final_md_path = output_dir / f"FINAL_CORPUS_SUMMARY_{safe_model}_{run_ts}.md"

    # ── Ollama setup ────────────────────────────────────────────────────────
    ollama_proc = None
    if args.start_ollama:
        ollama_proc = start_ollama_server()
        ensure_model_pulled(args.model)

    # ── Discover input files ─────────────────────────────────────────────────
    files = sorted(f.name for f in input_dir.iterdir() if f.suffix == ".txt")
    if not files:
        sys.exit(f"ERROR: No .txt files found in '{input_dir}'.")
    print(f"Found {len(files)} conversation file(s) in '{input_dir}'.")

    # ── MAP: summarise every file ────────────────────────────────────────────
    individual_summaries: dict = {}
    if args.resume:
        individual_summaries = load_existing_summaries(json_path)
        skipped = sum(1 for f in files if f in individual_summaries)
        print(f"Resuming: {skipped}/{len(files)} file(s) already summarised.")

    errors: list[str] = []
    to_process = [f for f in files if f not in individual_summaries]

    for filename in tqdm(to_process, desc="Summarising individual threads"):
        path = input_dir / filename
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
            summary = summarize_text(text, INDIVIDUAL_SYSTEM, args.model, args.max_chars)
            individual_summaries[filename] = summary
        except Exception as exc:
            print(f"\nWARNING: Failed to process '{filename}': {exc}", file=sys.stderr)
            errors.append(filename)
            continue

        # Save incrementally so a crash doesn't lose progress
        save_summaries(json_path, individual_summaries)

    print(f"\nIndividual summaries saved to '{json_path}' ({len(individual_summaries)} entries).")
    if errors:
        print(f"WARNING: {len(errors)} file(s) failed and were skipped: {errors}", file=sys.stderr)

    # ── REDUCE: corpus-level summary ─────────────────────────────────────────
    if args.skip_corpus:
        print("--skip-corpus set; skipping final corpus summary.")
    else:
        print("Generating corpus-level summary…")
        all_summaries_text = "\n\n---\n\n".join(
            f"--- Summary of {fn} ---\n{s}"
            for fn, s in individual_summaries.items()
        )

        if len(all_summaries_text) > CORPUS_CHUNK_THRESHOLD:
            print("  Corpus too large for a single pass — using intermediate chunking.")
            items = list(individual_summaries.items())
            chunks = [
                items[i : i + CORPUS_CHUNK_SIZE]
                for i in range(0, len(items), CORPUS_CHUNK_SIZE)
            ]
            intermediate: list[str] = []
            for i, chunk in enumerate(tqdm(chunks, desc="Intermediate chunk summaries")):
                chunk_text = "\n\n---\n\n".join(f"Summary of {fn}:\n{s}" for fn, s in chunk)
                inter = summarize_text(
                    chunk_text,
                    CORPUS_SYSTEM + f"\n\n(This is chunk {i + 1}/{len(chunks)})",
                    args.model,
                    args.max_chars,
                )
                intermediate.append(inter)
            all_summaries_text = "\n\n---\n\n".join(intermediate)

        final_summary = summarize_text(all_summaries_text, CORPUS_SYSTEM, args.model, args.max_chars)

        with open(final_md_path, "w", encoding="utf-8") as f:
            f.write(f"# Final Summary of Entire Reddit Conversation Corpus\n\n")
            f.write(f"**Model:** {args.model}  \n")
            f.write(f"**Generated:** {datetime.now().isoformat(timespec='seconds')}  \n")
            f.write(f"**Files processed:** {len(individual_summaries)}  \n\n")
            f.write("---\n\n")
            f.write(final_summary)

        print(f"Final corpus summary saved to '{final_md_path}'.")

    print("\nDone. You now have per-thread summaries (JSON) and a high-level corpus summary (Markdown).")

    if ollama_proc is not None:
        print("Stopping ollama server that was started by this script.")
        ollama_proc.terminate()


if __name__ == "__main__":
    main()
