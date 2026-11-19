# Sourced, not run: loads .env into the environment, if one can be found. A
# worktree has no .env of its own, so it falls back to the main checkout's.
# Sets DOTENV to the file it loaded, or leaves it empty.
DOTENV="$ROOT/.env"
if [ ! -f "$DOTENV" ]; then
    COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    DOTENV="${COMMON:+$(dirname "$COMMON")/.env}"
fi
if [ -n "$DOTENV" ] && [ -f "$DOTENV" ]; then
    set -a; source "$DOTENV"; set +a
else
    DOTENV=""
fi
