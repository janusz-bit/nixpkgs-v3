# ci-plan: the plan step of the build workflow. The workflow passes its
# values in the environment: DRV, NIXOS_REV, PUSH (cachix token set), MODE
# (rpi: the RPi cache secrets are set, else cachix), RPI_UP, MACHINES and the
# quotas; CACHE_URL, LOCAL_ONLY, RPI_CACHE_URL, NIXOS_REPO and MAX_MACHINES
# are workflow-wide. State of earlier runs: $RUNNER_TEMP/status.json and
# build-times.json (fetched from branch ci-state).
#
# Mode rpi: the RPi is the durable store (quota RPI_QUOTA_GB), cachix only
# carries what other runners of the same run need (CACHIX_SHARE_GB), and a
# second dry run against cache.nixos.org plus the RPi alone measures what
# the durable store still lacks. Nothing is built while the RPi is down or
# while exports of an earlier run still wait for their push, so a dropped
# Wi-Fi link never turns into rebuilt work.
state="$RUNNER_TEMP/status.json"
args=(--drv "$DRV" --cache "$CACHE_URL" --times "$RUNNER_TEMP/build-times.json" --out plan.json --local-only "$LOCAL_ONLY")
if [ "$PUSH" = true ]; then
  machines=${MACHINES:-$MAX_MACHINES}
  budget=18900
else
  machines=1
  budget=7200
fi
[ "$machines" -le "$MAX_MACHINES" ] || machines=$MAX_MACHINES

skip=""
if [ "$MODE" = rpi ]; then
  args+=(--quota-gb "$RPI_QUOTA_GB" --share-gb "$CACHIX_SHARE_GB")
  if [ "$RPI_UP" = true ]; then
    args+=(--durable "https://cache.nixos.org $RPI_CACHE_URL")
  else
    skip="the RPi cache is unreachable; the next scheduled run tries again"
  fi
  pending=$(jq -r '.unpushed // [] | join(", ")' "$state")
  [ -z "$pending" ] || skip="the exports of run(s) $pending are not in the RPi cache yet; this run pushes them first"
else
  # cachix alone: 40 % of the quota for the v3 world in all, counted over
  # runs (status.json .cachix_v3_gib), so the LRU never reaches the user's
  # other paths such as the CachyOS kernel.
  left=$(jq -r --arg q "$CACHIX_QUOTA_GB" '(($q | tonumber) * 0.4) - (.cachix_v3_gib // 0)' "$state")
  args+=(--quota-gb "$CACHIX_QUOTA_GB" --cap-gb "$left")
  if awk -v l="$left" 'BEGIN { exit !(l <= 0) }'; then
    skip="the v3 share of the cachix quota is used up (set the RPi cache secrets, or raise CACHIX_QUOTA_GB)"
  fi
fi

generic=$(nix eval --raw ./ci#generic.drvPath --override-input nixos "github:$NIXOS_REPO/$NIXOS_REV" 2>/dev/null || true)
[ -z "$generic" ] || args+=(--generic "$generic")
v3ci plan "${args[@]}" --machines "$machines" --budget "$budget" >plan-out.json

matrix=$(jq -c .matrix plan-out.json)
# Without the RPi a cache too small for the world gets one bounded share per
# janusz-bit/nixos revision at most.
if [ "$MODE" != rpi ] && [ "$(jq .capped plan-out.json)" = true ] &&
  [ "$(jq -r '.capped_rev // ""' "$state")" = "$NIXOS_REV" ]; then
  skip="the cachix quota is too small and this revision already got its share"
fi
if [ -n "$skip" ]; then
  matrix='[]'
  echo "Nothing built: $skip." >>"$GITHUB_STEP_SUMMARY"
fi
{
  echo "matrix=$matrix"
  echo "real=$(jq .real plan-out.json)"
  echo "capped=$(jq .capped plan-out.json)"
  echo "durable_missing=$(jq '.durable_missing // -1' plan-out.json)"
  echo "unpushed=$(jq '.unpushed // [] | length' "$state")"
} >>"$GITHUB_OUTPUT"
