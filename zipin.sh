#!/usr/bin/env bash
# zipin.sh
# If exactly one zip (or zip-like) file appeared in the repo root in the last 5
# minutes: pull latest, unzip with overwrite, delete the archive, git add the
# extracted directory, commit. No prompts.
set -euo pipefail

MAX_AGE_MIN=5

die() {
  echo "zipin: $*" >&2
  exit 1
}

# Resolve git root from wherever this was launched.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "not inside a git repository"
fi
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || die "cannot cd to $ROOT"

# Collect candidate archives at repo root only (no recursion).
# Prefer *.zip. Also accept a file whose name has no .zip if `file` says zip.
candidates=()
while IFS= read -r -d '' f; do
  candidates+=("$f")
done < <(find "$ROOT" -maxdepth 1 -type f -mmin "-${MAX_AGE_MIN}" \( -iname '*.zip' -o -iname '*.ZIP' \) -print0 2>/dev/null)

# Optional: recent non-.zip files that are actually zip archives.
if command -v file >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    case "$base" in
      *.zip|*.ZIP) continue ;;
    esac
    if file -b "$f" | grep -qi 'zip'; then
      candidates+=("$f")
    fi
  done < <(find "$ROOT" -maxdepth 1 -type f -mmin "-${MAX_AGE_MIN}" -print0 2>/dev/null)
fi

count="${#candidates[@]}"
if [ "$count" -eq 0 ]; then
  die "no zip created in the last ${MAX_AGE_MIN} minutes at repo root"
fi
if [ "$count" -gt 1 ]; then
  echo "zipin: found more than one recent archive:" >&2
  printf '  %s\n' "${candidates[@]}" >&2
  die "refusing to guess. Leave exactly one recent zip."
fi

ARCHIVE="${candidates[0]}"
ARCHIVE_BASE="$(basename "$ARCHIVE")"
# Stem = filename without a trailing .zip (any case). Used as the add path
# and as the name unzip will look for if we pass it without the suffix.
STEM="$ARCHIVE_BASE"
case "$STEM" in
  *.zip|*.ZIP) STEM="${STEM%.*}" ;;
esac

echo "zipin: archive = $ARCHIVE_BASE"
echo "zipin: stem    = $STEM"

# (0) Update from remote. Must succeed. No prompts.
export GIT_TERMINAL_PROMPT=0
export GIT_MERGE_AUTOEDIT=no
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" = "HEAD" ]; then
  die "detached HEAD. Check out a branch first."
fi

# Figure out what to pull without asking.
REMOTE="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [ -z "$REMOTE" ]; then
  if git remote get-url origin >/dev/null 2>&1; then
    if git ls-remote --heads origin "$BRANCH" >/dev/null 2>&1 && \
       git ls-remote --heads origin "$BRANCH" | grep -q .; then
      REMOTE="origin/${BRANCH}"
    elif git ls-remote --heads origin main >/dev/null 2>&1 && \
         git ls-remote --heads origin main | grep -q .; then
      REMOTE="origin/main"
    elif git ls-remote --heads origin master >/dev/null 2>&1 && \
         git ls-remote --heads origin master | grep -q .; then
      REMOTE="origin/master"
    else
      die "no upstream and cannot find origin/${BRANCH}, origin/main, or origin/master"
    fi
    echo "zipin: no upstream set. Pulling $REMOTE"
  else
    die "no upstream and no origin remote"
  fi
fi

echo "zipin: pulling (ff-only) $REMOTE"
# Fetch first so we fail fast on network, then ff-only so we never open an editor.
REMOTE_NAME="${REMOTE%%/*}"
REMOTE_REF="${REMOTE#*/}"
git fetch --quiet "$REMOTE_NAME" "$REMOTE_REF" || die "git fetch failed. Stopped before unzip."
if ! git merge-base --is-ancestor HEAD "$REMOTE_NAME/$REMOTE_REF" 2>/dev/null; then
  # HEAD has commits the remote does not, or histories diverged.
  if ! git merge-base --is-ancestor "$REMOTE_NAME/$REMOTE_REF" HEAD 2>/dev/null; then
    die "local and $REMOTE have diverged. Resolve that before ingesting a zip."
  fi
  echo "zipin: local is already ahead of $REMOTE. Continuing without merge."
else
  git merge --ff-only --quiet "$REMOTE_NAME/$REMOTE_REF" || die "ff-only pull failed. Stopped before unzip."
fi
echo "zipin: tree is up to date with $REMOTE"

# (1) Unzip, overwrite, no prompts.
# Info-ZIP accepts the stem and appends .zip if needed. Pass the real file to
# stay correct for unusual extensions.
if ! command -v unzip >/dev/null 2>&1; then
  die "unzip is not installed"
fi
echo "zipin: unzip -o $ARCHIVE_BASE"
unzip -o -q "$ARCHIVE" -d "$ROOT" || die "unzip failed"

# (2) Remove the archive immediately.
rm -f "$ARCHIVE"
echo "zipin: removed $ARCHIVE_BASE"

# Extracted path. Prefer the stem directory. If the zip dumped files at root
# instead, still add the stem if that directory now exists.
ADD_PATH="$STEM"
if [ ! -e "$ROOT/$ADD_PATH" ]; then
  die "after unzip, expected $ADD_PATH in the repo root and it is missing"
fi

# (3) Stage the directory. Git decides new vs modified.
git add -- "$ADD_PATH"
echo "zipin: git add $ADD_PATH"

# (4) Commit. No editor. Skip cleanly if nothing changed.
if git diff --cached --quiet; then
  echo "zipin: nothing new to commit (contents already match HEAD)"
  exit 0
fi

MSG="Ingest ${STEM} from zip ($(date -u +%Y-%m-%dT%H:%MZ))"
git commit -m "$MSG" || die "git commit failed (check user.name / user.email)"
echo "zipin: committed: $MSG"
git status --short
