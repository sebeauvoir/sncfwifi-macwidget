#!/usr/bin/env python3
"""Compose les notes de release à partir des commits depuis la version précédente.

Lu par `.github/workflows/build.yml`, mais exécutable à la main pour vérifier
le rendu avant de pousser :

    PREVIOUS=v1.0.3 VERSION=v1.0.4 python3 scripts/release_notes.py
"""

import os
import re
import subprocess
import sys

REPO_URL = os.environ.get("REPO_URL", "").rstrip("/")
PREVIOUS = os.environ.get("PREVIOUS", "").strip()
VERSION = os.environ.get("VERSION", "").strip()

# Les préfixes Conventional Commits utilisés par le dépôt, rangés par section.
SECTIONS = [
    ("✨ Nouveautés", {"feat"}),
    ("🐛 Corrections", {"fix"}),
    ("📖 Documentation", {"docs"}),
    ("🔧 Maintenance", {"chore", "ci", "build", "refactor", "perf", "style", "test"}),
    ("📦 Divers", set()),  # tout ce qui ne suit pas la convention
]

COMMIT = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]+)\))?!?: (?P<subject>.+)$")


def commits():
    """(sha court, type, scope, sujet) des commits depuis PREVIOUS, du plus récent au plus ancien."""
    span = f"{PREVIOUS}..HEAD" if PREVIOUS else "HEAD"
    out = subprocess.run(
        ["git", "log", "--no-merges", "--pretty=format:%h\t%s", span],
        capture_output=True, text=True, check=True,
    ).stdout

    for line in out.splitlines():
        sha, _, subject = line.partition("\t")
        match = COMMIT.match(subject)
        if match:
            yield sha, match["type"], match["scope"], match["subject"]
        else:
            yield sha, None, None, subject


def bullet(sha, scope, subject):
    link = f" ([`{sha}`]({REPO_URL}/commit/{sha}))" if REPO_URL else f" (`{sha}`)"
    prefix = f"**{scope}** — " if scope else ""
    return f"- {prefix}{subject}{link}"


def main():
    grouped = {title: [] for title, _ in SECTIONS}
    for sha, type_, scope, subject in commits():
        title = next(t for t, types in SECTIONS if type_ in types or not types)
        grouped[title].append(bullet(sha, scope, subject))

    if not any(grouped.values()):
        print("_Aucun changement de code depuis la version précédente._\n")
    else:
        for title, _ in SECTIONS:
            if grouped[title]:
                print(f"### {title}\n")
                print("\n".join(grouped[title]))
                print()

    print("---\n")
    print("**Installation** — décompressez `SNCFWifi.zip` et glissez `SNCFWifi.app` dans "
          "`/Applications`. L'app est signée en ad-hoc : au premier lancement, faites un clic "
          "droit → **Ouvrir**, ou lancez `xattr -cr /Applications/SNCFWifi.app`.")
    print()
    print("Binaire universel (Apple Silicon + Intel), macOS 11 ou plus récent.")

    if REPO_URL and PREVIOUS and VERSION:
        print(f"\n**Diff complet** : {REPO_URL}/compare/{PREVIOUS}...{VERSION}")


if __name__ == "__main__":
    sys.exit(main())
