#! /usr/bin/env python3 
import os
from convokit import download, Corpus
import random
import json  # for optional Discord sample

# ================== CONFIG ==================
OUTPUT_DIR = "conversation_samples"
NUM_CONVERSATIONS = 300      # Adjust as needed (small for testing)
MAX_TURNS_PER_CONV = 10      # Keep conversations short (Discord-like)
# ===========================================

os.makedirs(OUTPUT_DIR, exist_ok=True)

# 1. Load Reddit Corpus (threaded discussions)
print("Downloading/loading small Reddit corpus...")
corpus_path = download("reddit-corpus-small")   # Small & fast (~hundreds of threads)
corpus = Corpus(filename=corpus_path)

print(f"Loaded {len(list(corpus.iter_conversations()))} conversations from Reddit.")

# 2. Extract Reddit threads to .txt
reddit_output = os.path.join(OUTPUT_DIR, "reddit_threads.txt")
count = 0
with open(reddit_output, "w", encoding="utf-8") as f:
    for convo in corpus.iter_conversations():
        if count >= NUM_CONVERSATIONS:
            break
        utterances = list(convo.iter_utterances())
        if len(utterances) < 3 or len(utterances) > MAX_TURNS_PER_CONV:
            continue  # Skip too short/long
        
        f.write(f"=== THREAD {convo.id} ===\n")
        for u in utterances[:MAX_TURNS_PER_CONV]:
            speaker = u.speaker.id if u.speaker else "unknown"
            f.write(f"{speaker}: {u.text.strip()}\n")
        f.write("\n" + "="*80 + "\n\n")
        count += 1

print(f"Saved {count} Reddit threads to {reddit_output}")

# 3. Sample Discord-style chat (multi-turn, rapid replies)
# Using a small public multi-turn sample (or fallback to Reddit simulation)
discord_output = os.path.join(OUTPUT_DIR, "discord_style_chats.txt")
print("\nCreating sample Discord-style conversations...")

with open(discord_output, "w", encoding="utf-8") as f:
    for i in range(min(100, NUM_CONVERSATIONS // 2)):  # ~100 Discord-style
        f.write(f"=== DISCORD-STYLE CHAT {i+1} ===\n")
        # Simulate realistic chat (you can replace with real Discord data later)
        turns = [
            "user1: Hey guys, anyone tried the new update?",
            "user2: Yeah it's buggy af lol",
            "user3: Works fine on my end, what OS?",
            "user1: Windows 11, keeps crashing",
            "user4: Same here, reported the bug already",
            "user2: +1"
        ]
        for turn in turns[:random.randint(4, MAX_TURNS_PER_CONV)]:
            f.write(turn + "\n")
        f.write("\n" + "="*80 + "\n\n")

print(f"Saved Discord-style samples to {discord_output}")

print("\n✅ Done! Check the folder:", OUTPUT_DIR)
print("Files are ready for your app — simple text with clear separators.")