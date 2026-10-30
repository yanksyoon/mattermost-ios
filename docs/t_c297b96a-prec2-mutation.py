#!/usr/bin/env python3
"""t_c297b96a — apply the pre-C2 Button container to all three list hosts (measurement only).

Each mutation restores exactly one variable — the row container — and keeps everything
C2 added around it (the onShowProfile callback, the combined accessibility element, the
label and the Open profile action), so a difference in outcome can only be the container.
Run `--revert` to put the tree back; the script refuses to guess if an anchor is missing.
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent / "repro"

MUTATIONS = {
    "Mattermost/UI/Native/Search/SearchView.swift": [
        (
            """    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.channelLabel)""",
            """    var body: some View {
        // t_c297b96a F1 measurement (reverted): the pre-C2 container, callback kept.
        Button(action: onOpen) {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.channelLabel)""",
        ),
        (
            """            .environment(\\.searchHighlightTerms, row.highlight)
        }
        // The whole row jumps to the message; the author's two buttons keep their own areas (a tap on
        // them never reaches this gesture — SwiftUI hit-tests the inner control first).
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .accessibilityAddTraits(.isButton)""",
            """            .environment(\\.searchHighlightTerms, row.highlight)
        }
        }
        // t_c297b96a F1 measurement (reverted): the row is a Button again, so there is no gesture.
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)""",
        ),
    ],
    "Mattermost/UI/Native/Search/SavedPinnedViews.swift": [
        (
            """                    VStack(alignment: .leading, spacing: 2) {
                        // A saved row says which channel it came from: the tab is team-scoped and""",
            """                    // t_c297b96a F1 measurement (reverted): the pre-C2 container, callback kept.
                    Button {
                        open(row)
                    } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        // A saved row says which channel it came from: the tab is team-scoped and""",
        ),
        (
            """                    }
                    .contentShape(Rectangle())
                    .onTapGesture { open(row) }
                    .accessibilityAddTraits(.isButton)""",
            """                    }
                    }
                    // t_c297b96a F1 measurement (reverted): the row is a Button again.
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)""",
        ),
    ],
    "Mattermost/UI/Native/Activity/MentionsView.swift": [
        (
            """    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()""",
            """    var body: some View {
        // t_c297b96a F1 measurement (reverted): the pre-C2 container, callback kept.
        Button(action: onOpen) {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()""",
        ),
        (
            """        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .accessibilityAddTraits(.isButton)
        // One combined element rather than three:""",
            """        }
        }
        // t_c297b96a F1 measurement (reverted): the row is a Button again, so there is no gesture.
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        // One combined element rather than three:""",
        ),
    ],
}


def apply() -> None:
    for rel, edits in MUTATIONS.items():
        path = REPO / rel
        text = path.read_text()
        for old, new in edits:
            count = text.count(old)
            if count != 1:
                sys.exit(f"{rel}: anchor appears {count} times (expected 1):\n{old[:120]}")
            text = text.replace(old, new)
        path.write_text(text)
        print(f"mutated {rel}")


def revert() -> None:
    subprocess.run(["git", "checkout", "--", *MUTATIONS], cwd=REPO, check=True)
    print("reverted: " + ", ".join(MUTATIONS))


if __name__ == "__main__":
    if "--revert" in sys.argv:
        revert()
    else:
        apply()
