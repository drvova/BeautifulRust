#!/usr/bin/env bash
# Merges upstream's main into the current branch while keeping this fork omp-native.
#
# - Upstream's Claude Code plugin (.claude-plugin/) is dropped from the merge.
# - Upstream's version bumps in .claude-plugin/plugin.json are copied to package.json.
# - Where both sides changed the same lines, this fork's side wins (-X ours). Rename
#   detection is off so upstream's plugin.json is never matched to package.json.
# - .github/workflows/ stays as this fork has it: a GITHUB_TOKEN cannot push workflow
#   changes, and upstream's workflows serve upstream's own CI and website.
#
# Leaves a merge commit on success and changes nothing if the fork is already up to date.
# Exits 1, with the merge aborted, if a conflict still needs a person.
#
# Usage: scripts/sync-upstream.sh [upstream-url] [upstream-branch]
set -euo pipefail

url="${1:-https://github.com/morganlinton/BeautifulRust.git}"
branch="${2:-main}"

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream "$url"
else
  git remote add upstream "$url"
fi
git fetch --quiet --no-tags upstream "$branch"
theirs="upstream/$branch"

if git merge-base --is-ancestor "$theirs" HEAD; then
  echo "Already up to date with $theirs."
  exit 0
fi

git merge --quiet --no-commit --no-ff -X ours -X no-renames "$theirs" || true

git rm -r -q -f --cached --ignore-unmatch .claude-plugin
rm -rf .claude-plugin

git diff --cached --name-only --diff-filter=A HEAD -- .github/workflows |
  xargs -r git rm -q -f
git checkout HEAD -- .github/workflows

conflicts="$(git diff --name-only --diff-filter=U)"
if [ -n "$conflicts" ]; then
  echo "::error::Merging $theirs left conflicts that need a person:"
  echo "$conflicts"
  git merge --abort
  exit 1
fi

if upstream_plugin="$(git show "$theirs:.claude-plugin/plugin.json" 2>/dev/null)"; then
  UPSTREAM_PLUGIN="$upstream_plugin" python3 - <<'PY'
import json
import os

version = json.loads(os.environ["UPSTREAM_PLUGIN"]).get("version")
with open("package.json", encoding="utf-8") as f:
    package = json.load(f)
if isinstance(version, str) and package.get("version") != version:
    print("package.json version: %s -> %s" % (package.get("version"), version))
    package["version"] = version
    with open("package.json", "w", encoding="utf-8") as f:
        json.dump(package, f, indent=2, ensure_ascii=False)
        f.write("\n")
PY
  git add package.json
fi

git commit --quiet --no-edit -m "Merge upstream $branch ($(git rev-parse --short "$theirs"))"
echo "Merged $theirs."
