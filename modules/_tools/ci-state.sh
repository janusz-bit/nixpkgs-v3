# ci-state MESSAGE [NAME=PATH]... -- JQ_ARGS...: applies jq with JQ_ARGS to
# status.json on branch ci-state, copies each PATH there as NAME, commits and
# pushes. finalize, rpi-push and marker of different runs write the branch,
# so a rejected push starts over from the new tip. Runs inside the checkout,
# whose persisted credentials (actions/checkout) the push uses.
msg=$1
shift
files=()
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  files+=("$1")
  shift
done
shift
work="$RUNNER_TEMP/ci-state"
for attempt in 1 2 3 4 5; do
  git worktree remove --force "$work" 2>/dev/null || rm -rf "$work"
  git worktree prune
  if git fetch -q origin ci-state; then
    git worktree add -q --detach "$work" FETCH_HEAD
  else
    git worktree add -q --detach "$work"
    git -C "$work" checkout -q --orphan ci-state-new
    git -C "$work" rm -rqf .
  fi
  [ -f "$work/status.json" ] || echo '{}' >"$work/status.json"
  jq "$@" "$work/status.json" >"$work/status.json.new"
  mv "$work/status.json.new" "$work/status.json"
  for f in "${files[@]}"; do
    cp "${f#*=}" "$work/${f%%=*}"
  done
  git -C "$work" add -A
  if git -C "$work" diff --cached --quiet; then
    exit 0
  fi
  git -C "$work" -c user.name="github-actions[bot]" -c user.email="github-actions[bot]@users.noreply.github.com" \
    commit -qm "$msg"
  if git -C "$work" push -q origin HEAD:refs/heads/ci-state; then
    exit 0
  fi
  sleep $((attempt * 5))
done
echo "ci-state: could not push" >&2
exit 1
