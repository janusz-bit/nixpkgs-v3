# ci-rpi-push: the only job that uploads to the RPi cache (one job per run,
# concurrency group rpi-push across runs, one path at a time): every output
# the builders exported ($ARTIFACTS/export-*), the exports of earlier runs
# whose push did not finish (status.json .unpushed, artifacts of 7 days),
# and the outputs the plan found only in another cache (.durable.repush, for
# example the CachyOS kernel from cachix). Uploads go through nix-cache-push
# of janusz-bit/nixos ($PUSH_TOOL), rate-limited by $RPI_LIMIT_RATE through
# curl's config file: the RPi is on Wi-Fi, and parallel large uploads have
# dropped it off the network.
#
# Writes outputs pushed=true|false, carried (run ids whose exports were
# taken), unpushed (the ones still waiting) and up_mib_s/down_mib_s of a
# 32 MiB probe of the link.
exp="$RUNNER_TEMP/export"
mkdir -p "$exp/nar"
printf 'StoreDir: /nix/store\n' >"$exp/nix-cache-info"

# Real narinfos only: stubs (exports of references) stand for paths that
# come from elsewhere, and a stub must not shadow another runner's export.
merge() {
  local d f
  for d in "$1"/export-*/; do
    [ -d "$d" ] || continue
    if [ -d "$d/nar" ]; then cp -rn "$d/nar/." "$exp/nar/"; fi
    for f in "$d"*.narinfo; do
      [ -e "$f" ] || continue
      grep -qx 'URL: nar/stub' "$f" || cp -f "$f" "$exp/"
    done
  done
}

carried=()
if compgen -G "$ARTIFACTS/export-*" >/dev/null; then
  merge "$ARTIFACTS"
  carried+=("$GITHUB_RUN_ID")
fi
for id in $(jq -r '.unpushed // [] | .[]' "$RUNNER_TEMP/status.json"); do
  [ "$id" != "$GITHUB_RUN_ID" ] || continue
  if gh run download "$id" --repo "$GITHUB_REPOSITORY" --pattern 'export-*' --dir "$RUNNER_TEMP/pending/$id"; then
    merge "$RUNNER_TEMP/pending/$id"
    carried+=("$id")
  else
    echo "::warning::the exports of run $id are gone; what is not in a cache gets rebuilt"
  fi
done

paths="$RUNNER_TEMP/paths"
{
  sed -n 's/^StorePath: //p' "$exp"/*.narinfo 2>/dev/null || true
  jq -r '.durable.repush // [] | .[]' "$PLAN"
} | sort -u >"$paths"
echo "Paths for the RPi cache: $(wc -l <"$paths")" | tee -a "$GITHUB_STEP_SUMMARY"

# Link probe, before the rate limit applies: a 32 MiB file under nar/, which
# nix-cache-gc removes after a day as a NAR no narinfo references.
umask 077
host=${RPI_CACHE_URL#*://}
host=${host%%[:/]*}
printf 'machine %s login ci password %s\n' "$host" "$NIX_CACHE_PUSH_PASSWORD" >"$RUNNER_TEMP/netrc"
head -c 33554432 /dev/urandom >"$RUNNER_TEMP/probe"
probe="$RPI_CACHE_URL/nar/speedtest-$GITHUB_RUN_ID.nar"
mib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'; }
up=$(curl -sS --fail --connect-timeout 10 --max-time 300 --netrc-file "$RUNNER_TEMP/netrc" \
  --upload-file "$RUNNER_TEMP/probe" -o /dev/null -w '%{speed_upload}' "$probe" || echo 0)
down=$(curl -sS --fail --connect-timeout 10 --max-time 300 -o /dev/null -w '%{speed_download}' "$probe" || echo 0)
rm -f "$RUNNER_TEMP/netrc" "$RUNNER_TEMP/probe"
echo "RPi link (32 MiB, one stream): upload $(mib "$up") MiB/s, download $(mib "$down") MiB/s" | tee -a "$GITHUB_STEP_SUMMARY"

pushed=true
if [ -s "$paths" ]; then
  xargs -a "$paths" nix-store --realise --keep-going \
    --option extra-substituters "file://$exp?trusted=1" >/dev/null 2>"$RUNNER_TEMP/realise.log" ||
    { echo "::warning::not every path could be fetched for the push"; tail -n 20 "$RUNNER_TEMP/realise.log"; }
  xargs -a "$paths" nix-store --check-validity --print-invalid >"$RUNNER_TEMP/invalid" || true
  grep -vxF -f "$RUNNER_TEMP/invalid" "$paths" >"$RUNNER_TEMP/valid" || true
  export CURL_HOME="$RUNNER_TEMP/curl"
  mkdir -p "$CURL_HOME"
  printf 'limit-rate = %s\n' "$RPI_LIMIT_RATE" >"$CURL_HOME/.curlrc"
  start=$(date +%s)
  if ! xargs -a "$RUNNER_TEMP/valid" "$PUSH_TOOL"; then
    pushed=false
    echo "::warning::the push to the RPi cache stopped; the next run pushes again"
  fi
  echo "Pushed $(wc -l <"$RUNNER_TEMP/valid") paths in $(($(date +%s) - start)) s (limit $RPI_LIMIT_RATE/s), complete: $pushed" |
    tee -a "$GITHUB_STEP_SUMMARY"
fi

unpushed=""
[ "$pushed" = true ] || unpushed="${carried[*]}"
{
  echo "pushed=$pushed"
  echo "carried=${carried[*]}"
  echo "unpushed=$unpushed"
  echo "up_mib_s=$(mib "$up")"
  echo "down_mib_s=$(mib "$down")"
} >>"$GITHUB_OUTPUT"
