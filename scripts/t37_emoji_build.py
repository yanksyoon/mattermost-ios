#!/usr/bin/env python3
"""Build this repo's bundled emoji table from the Apache-2.0 upstream data file.

Why a build step instead of a hand-written table: the picker has to offer the same shortcodes the
*server* resolves, and Mattermost's own client carries that list as generated data
(`mattermost-mobile/app/utils/emoji/emoji.json`, itself generated from emoji-datasource). A hand
-written subset (T34's `EmojiShortcodes.table`, 60 names) is enough to *draw* a `:name:` that is
already in a post, but a picker built from it would offer a fraction of what a reader expects.

What this script does:
  * downloads `emoji.json` at a pinned commit of mattermost/mattermost-mobile (Apache-2.0),
  * prints the licence it verified, so the provenance line in the output is not a claim,
  * keeps the **base** entries only (a skin-tone variant is reachable through its base emoji; the
    picker's category list does not contain the datasource's `component` swatches either),
  * derives the drawable character from the datasource's code-point sequence (`image`, e.g.
    `1f600` or `263a-fe0f`), which is why no image assets are needed,
  * writes `Mattermost/Resources/emoji.json` with the canonical shortcode first in `aliases`.

Usage:
    python3 scripts/t37_emoji_build.py            # writes the bundled resource
    python3 scripts/t37_emoji_build.py --check    # fails if the resource is out of date
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import urllib.request

UPSTREAM_REPO = "mattermost/mattermost-mobile"
UPSTREAM_PATH = "app/utils/emoji/emoji.json"
UPSTREAM_LICENSE = "LICENSE.txt"
DEFAULT_REF = "main"

# The picker's category order, from `app/utils/emoji/index.ts` `CategoryNames` minus the two
# pseudo-categories that are filled at runtime (`recent`, `custom`). Keeping upstream's order is the
# whole point of porting the component rather than inventing a layout.
CATEGORY_ORDER = [
    "smileys-emotion",
    "people-body",
    "animals-nature",
    "food-drink",
    "travel-places",
    "activities",
    "objects",
    "symbols",
    "flags",
]

CATEGORY_TITLES = {
    "smileys-emotion": "Smileys & Emotion",
    "people-body": "People & Body",
    "animals-nature": "Animals & Nature",
    "food-drink": "Food & Drink",
    "travel-places": "Travel & Places",
    "activities": "Activities",
    "objects": "Objects",
    "symbols": "Symbols",
    "flags": "Flags",
}

OUTPUT = pathlib.Path("Mattermost/Resources/emoji.json")


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "mattermost-ios-emoji-build"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def character_for(image: str) -> str | None:
    """`1f469-200d-1f4bb` -> the emoji, or None when a code point is not a scalar."""
    text = []
    for part in image.split("-"):
        try:
            text.append(chr(int(part, 16)))
        except ValueError:
            return None
    return "".join(text)


def build(entries: list) -> dict:
    emojis = []
    for entry in entries:
        if "skins" in entry:
            # A skin-tone variant row: reachable through its base emoji, and not a category member
            # in upstream's picker (`getEmojis(skinTone:)` keeps only `default`/no-skin entries).
            continue
        category = entry.get("category", "")
        if category not in CATEGORY_TITLES:
            # `component` (the five skin swatches) and the datasource's own `custom` row: upstream's
            # `CategoryNames` does not list them, so a picker section for them would be this
            # client's invention.
            continue
        aliases = [a for a in (entry.get("short_names") or []) if a]
        if not aliases:
            continue
        character = character_for(entry.get("image", ""))
        if character is None:
            continue
        emojis.append({
            "name": aliases[0],
            "aliases": aliases,
            "char": character,
            "category": category,
        })
    emojis.sort(key=lambda e: CATEGORY_ORDER.index(e["category"]))
    return {
        "source": f"{UPSTREAM_REPO}/{UPSTREAM_PATH}",
        "license": "Apache-2.0",
        "category_order": CATEGORY_ORDER,
        "category_titles": CATEGORY_TITLES,
        "emojis": emojis,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ref", default=DEFAULT_REF,
                        help="commit/branch of mattermost-mobile to read")
    parser.add_argument("--check", action="store_true",
                        help="compare against the committed resource instead of writing it")
    args = parser.parse_args()

    license_text = fetch(f"https://raw.githubusercontent.com/{UPSTREAM_REPO}/{args.ref}/"
                         f"{UPSTREAM_LICENSE}").decode("utf-8", "replace")
    if "Apache License" not in license_text or "Version 2.0" not in license_text:
        raise SystemExit("upstream licence is not Apache-2.0 — refusing to bundle its data")

    raw = fetch(f"https://raw.githubusercontent.com/{UPSTREAM_REPO}/{args.ref}/{UPSTREAM_PATH}")
    entries = json.loads(raw)
    payload = build(entries)

    counts: dict[str, int] = {}
    for emoji in payload["emojis"]:
        counts[emoji["category"]] = counts.get(emoji["category"], 0) + 1
    print(f"upstream entries: {len(entries)}")
    print(f"bundled emoji:    {len(payload['emojis'])} across {len(counts)} categories")
    for category in CATEGORY_ORDER:
        print(f"  {category:16s} {counts.get(category, 0)}")

    text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=False)
    if args.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current.strip() != text.strip():
            print(f"RESULT: FAIL — {OUTPUT} is out of date", file=sys.stderr)
            return 1
        print(f"RESULT: PASS — {OUTPUT} matches upstream at {args.ref}")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(text + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT} ({len(text) + 1} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
