# GitHub Actions workflows, generated with github-actions-nix as in
# janusz-bit/nixos: `nix run .#sync-github-actions` (also a pre-commit hook)
# rewrites .github/workflows/ and removes workflows that are gone.
#
# - lint: pre-commit check (nixfmt, statix, deadnix, actionlint, generated
#   workflows up to date) and the CI tools build (flake8, shellcheck).
# - eval: flake checks, toolchain assertions and the world target.
# - build: the world build of the laptop of janusz-bit/nixos on x86-64-v3.
#   plan evaluates ci#v3, dry-runs it and list-schedules what is missing over
#   up to 16 runners (_tools/ci-plan.sh, v3ci plan); build runs one share per
#   runner; rpi-push takes the run's outputs to the tailnet cache on the RPi
#   (_tools/ci-rpi-push.sh); finalize records measured times on branch
#   ci-state and dispatches the next run while progress is made; marker tags
#   cached/nixos-<rev> once the RPi cache and cache.nixos.org hold the whole
#   closure. Never for pull requests: the jobs hold the cachix token and the
#   RPi cache secrets.
# - proof: ELF scan and A/B benchmark, once the sample packages are cached.
#
# Two stores. The RPi cache of janusz-bit/nixos (hosts/nix-cache.nix there:
# ~750 GB, tailnet only, signed by CI with NIX_CACHE_SIGNING_KEY) is the
# durable one; uploads go through one job at a time with a rate limit,
# because the RPi is on Wi-Fi. cachix (5 GB free plan, LRU, also holds the
# laptop's CachyOS kernel) carries only what runners of the same run take
# from each other, capped by CACHIX_SHARE_GB. Without the RPi secrets
# (TS_OAUTH_CLIENT_ID, TS_AUDIENCE, NIX_CACHE_SIGNING_KEY,
# NIX_CACHE_PUSH_PASSWORD) the build falls back to cachix alone: one bounded
# share per revision (CACHIX_QUOTA_GB) and no marker. Without
# CACHIX_AUTH_TOKEN it runs on one runner for 2 h without push.
#
# The matrix is static (machine 0..15): github-actions-nix types matrix
# values as lists, so a fromJSON matrix is not expressible. A runner the plan
# leaves without work skips its steps after the first.
#
# Actions are pinned to commit SHAs (tag in the comment): tags can move, and
# the jobs see the cachix token, the RPi cache signing key and, in finalize,
# rpi-push and marker, `contents: write`. New SHA:
# `git ls-remote https://github.com/<repo> 'refs/tags/<tag>^{}' 'refs/tags/<tag>'`.
#
# Check: `nix run .#sync-github-actions && git status --short .github/workflows`
# (empty = the workflows in the repo match this file).
_: {
  perSystem =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      actions = {
        checkout = "actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803"; # v6
        installNix = "cachix/install-nix-action@bb0495a1086c46893eee56f32fd192dfe4a15bb9"; # v32
        cachix = "cachix/cachix-action@38b082610b782e7e93e209c35fd730d399dee866"; # v17
        uploadArtifact = "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9"; # v7
        downloadArtifact = "actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131"; # v7
        # The same as janusz-bit/nixos uses for its RPi cache.
        tailscale = "tailscale/github-action@064b10558093f38325e838ddea35486bdc6b1d5c"; # v4.4.0
      };

      cache = {
        name = "janusz-bit";
        url = "https://janusz-bit.cachix.org";
        pubKey = "janusz-bit.cachix.org-1:4stTiufAF02BAXw8HNvYslAmUlPbZPIRhIGht0gSMoo=";
      };
      # customTop.nixCache of janusz-bit/nixos (modules/args.nix there); this
      # flake has no nixos input, so the values are repeated here. The cache
      # has two signers: janusz-bit/nixos CI (publicKey) and this repository
      # (v3PublicKey, the public half of NIX_CACHE_SIGNING_KEY here).
      rpiCache = {
        url = "https://raspberry-pi-4.tail1ea20e.ts.net:8444";
        publicKey = "janusz-bit-ci-1:sZOoPt8moauyLh35tiK6hcpnLfPySRm1C2IN/DffoVE=";
        v3PublicKey = "janusz-bit-v3-1:nESt1tMO6HoJe3AcnJ5Gj+VTNyz2suKd7hJOp8vQBbk=";
      };
      nixosRepo = "janusz-bit/nixos";
      maxMachines = 16;
      # Cheap intermediates (source copies, vendored crates): never pushed
      # and rebuilt by whichever runner needs them.
      localOnly = "(-src|-vendor|-source)(-[0-9][^-]*)?$";

      out = job: name: "\${{ needs.${job}.outputs.${name} }}";
      rpiMode = "needs.plan.outputs.mode == 'rpi'";

      checkout = {
        name = "Checkout repository";
        uses = actions.checkout;
      };
      checkoutFull = checkout // {
        with_.fetch-depth = 0;
      };

      # Same Nix as the RPi that develops this repo; the installer verifies
      # its tarball hashes.
      installNix = extraConfig: {
        name = "Install Nix";
        uses = actions.installNix;
        with_ = {
          install_url = "https://releases.nixos.org/nix/nix-2.35.6/install";
          extra_nix_config = ''
            experimental-features = nix-command flakes
            access-tokens = github.com=''${{ secrets.GITHUB_TOKEN }}
          ''
          + extraConfig;
        };
      };
      # The RPi cache comes last (no Priority in its nix-cache-info: 50 after
      # cache.nixos.org 40 and cachix), so runners take what cachix has from
      # cachix; connect-timeout as on the laptop: an RPi off the network must
      # not stall every lookup.
      v3Config = ''
        extra-substituters = ${cache.url} ${rpiCache.url}
        extra-trusted-public-keys = ${cache.pubKey} ${rpiCache.publicKey} ${rpiCache.v3PublicKey}
        extra-system-features = gccarch-x86-64 gccarch-x86-64-v2 gccarch-x86-64-v3
        connect-timeout = 5
      '';
      # Negative narinfo answers must not be cached: a path another runner
      # pushes a minute later has to be seen at once.
      builderConfig = v3Config + ''
        narinfo-cache-negative-ttl = 0
        build-dir = /nix/var/nix/builds
        max-silent-time = 3600
      '';

      # As in janusz-bit/nixos: an unreachable tailnet is a warning; the job
      # goes on without the RPi cache.
      connectTailnet = condition: {
        name = "Connect to the tailnet";
        if_ = condition;
        uses = actions.tailscale;
        continueOnError = true;
        with_ = {
          oauth-client-id = "\${{ secrets.TS_OAUTH_CLIENT_ID }}";
          audience = "\${{ secrets.TS_AUDIENCE }}";
          tags = "tag:ci";
        };
      };

      reclaimDisk = {
        name = "Reclaim disk space";
        # /mnt is the larger temporary disk: /nix (store and build
        # directory) moves there before Nix is installed.
        run = ''
          df -h / /mnt
          sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache /usr/local/share/boost \
            /usr/local/graalvm /usr/local/share/powershell /usr/share/swift /usr/local/.ghcup &
          sudo docker image prune --all --force >/dev/null 2>&1 &
          sudo mkdir -p /mnt/nix /nix && sudo mount --bind /mnt/nix /nix
          wait
          df -h / /mnt
        '';
      };

      # Earlier runs' state: status.json and build-times.json of branch
      # ci-state, into $RUNNER_TEMP (not the checkout, where ci-state's own
      # files would block switching to that branch).
      fetchState = {
        name = "Fetch the state of earlier runs";
        run = ''
          if git fetch -q --depth=1 origin ci-state; then
            git show FETCH_HEAD:status.json >"$RUNNER_TEMP/status.json" || echo '{}' >"$RUNNER_TEMP/status.json"
            git show FETCH_HEAD:build-times.json >"$RUNNER_TEMP/build-times.json" || echo '{}' >"$RUNNER_TEMP/build-times.json"
          else
            echo '{}' >"$RUNNER_TEMP/status.json"
            echo '{}' >"$RUNNER_TEMP/build-times.json"
          fi
        '';
      };

      evalTarget =
        rev: "nix eval --raw ./ci#v3.drvPath --override-input nixos \"github:$NIXOS_REPO/${rev}\"";

      plan = {
        runsOn = "ubuntu-latest";
        timeoutMinutes = 90;
        permissions = {
          contents = "read";
          id-token = "write";
        };
        outputs = {
          matrix = "\${{ steps.plan.outputs.matrix }}";
          real = "\${{ steps.plan.outputs.real }}";
          capped = "\${{ steps.plan.outputs.capped }}";
          durable_missing = "\${{ steps.plan.outputs.durable_missing }}";
          unpushed = "\${{ steps.plan.outputs.unpushed }}";
          nixos_rev = "\${{ steps.rev.outputs.nixos_rev }}";
          drv = "\${{ steps.eval.outputs.drv }}";
          push = "\${{ steps.secrets.outputs.push }}";
          mode = "\${{ steps.secrets.outputs.mode }}";
          rpi_up = "\${{ steps.rpi.outputs.up }}";
        };
        steps = [
          checkout
          {
            name = "Which secrets are set";
            id = "secrets";
            env = {
              CACHIX_AUTH_TOKEN = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
              TS_OAUTH_CLIENT_ID = "\${{ secrets.TS_OAUTH_CLIENT_ID }}";
              TS_AUDIENCE = "\${{ secrets.TS_AUDIENCE }}";
              NIX_CACHE_SIGNING_KEY = "\${{ secrets.NIX_CACHE_SIGNING_KEY }}";
              NIX_CACHE_PUSH_PASSWORD = "\${{ secrets.NIX_CACHE_PUSH_PASSWORD }}";
            };
            run = ''
              if [ -n "$CACHIX_AUTH_TOKEN" ]; then push=true; else push=false; fi
              if [ -n "$TS_OAUTH_CLIENT_ID" ] && [ -n "$TS_AUDIENCE" ] && [ -n "$NIX_CACHE_SIGNING_KEY" ] && [ -n "$NIX_CACHE_PUSH_PASSWORD" ]; then
                mode=rpi
              else
                mode=cachix
                echo "::warning::RPi cache secrets missing: cachix alone, one bounded share per revision, no fully-cached marker"
              fi
              { echo "push=$push"; echo "mode=$mode"; } >>"$GITHUB_OUTPUT"
            '';
          }
          (installNix v3Config)
          (connectTailnet "steps.secrets.outputs.mode == 'rpi'")
          {
            name = "Is the RPi cache reachable";
            id = "rpi";
            run = ''
              if curl -sf --connect-timeout 10 --max-time 30 -o /dev/null "$RPI_CACHE_URL/nix-cache-info"; then up=true; else up=false; fi
              echo "up=$up" >>"$GITHUB_OUTPUT"
              echo "RPi cache reachable: $up" >>"$GITHUB_STEP_SUMMARY"
            '';
          }
          {
            name = "Resolve the janusz-bit/nixos revision";
            id = "rev";
            run = ''
              ref=''${{ inputs.nixos_ref || 'master' }}
              rev=$(git ls-remote "https://github.com/$NIXOS_REPO" "$ref" "refs/heads/$ref" | head -1 | cut -f1)
              [ -n "$rev" ] || rev=$ref
              echo "nixos_rev=$rev" >> "$GITHUB_OUTPUT"
              echo "Target: $NIXOS_REPO@$rev, nixpkgs-v3@$GITHUB_SHA" >> "$GITHUB_STEP_SUMMARY"
            '';
          }
          {
            name = "Evaluate the world target";
            id = "eval";
            run = ''echo "drv=$(${evalTarget "\${{ steps.rev.outputs.nixos_rev }}"})" >> "$GITHUB_OUTPUT"'';
          }
          fetchState
          {
            name = "Plan";
            id = "plan";
            env = {
              DRV = "\${{ steps.eval.outputs.drv }}";
              NIXOS_REV = "\${{ steps.rev.outputs.nixos_rev }}";
              PUSH = "\${{ steps.secrets.outputs.push }}";
              MODE = "\${{ steps.secrets.outputs.mode }}";
              RPI_UP = "\${{ steps.rpi.outputs.up }}";
              MACHINES = "\${{ inputs.machines || '${toString maxMachines}' }}";
              CACHIX_QUOTA_GB = "\${{ vars.CACHIX_QUOTA_GB || '5' }}";
              CACHIX_SHARE_GB = "\${{ vars.CACHIX_SHARE_GB || '1' }}";
              RPI_QUOTA_GB = "\${{ vars.RPI_QUOTA_GB || '600' }}";
            };
            run = "nix run .#ci-plan";
          }
          {
            name = "Upload the plan";
            uses = actions.uploadArtifact;
            with_ = {
              name = "plan";
              path = "plan.json";
              retention-days = 7;
            };
          }
        ];
      };

      marker = {
        needs = "plan";
        if_ = lib.concatStringsSep " && " [
          rpiMode
          "needs.plan.outputs.rpi_up == 'true'"
          "needs.plan.outputs.durable_missing == '0'"
          "needs.plan.outputs.unpushed == '0'"
        ];
        runsOn = "ubuntu-latest";
        permissions.contents = "write";
        steps = [
          checkoutFull
          (installNix "")
          {
            name = "Publish the fully-cached marker";
            env = {
              NIXOS_REV = out "plan" "nixos_rev";
              DRV = out "plan" "drv";
            };
            run = ''
              tag="cached/nixos-$NIXOS_REV"
              git config user.name "github-actions[bot]"
              git config user.email "github-actions[bot]@users.noreply.github.com"
              if ! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
                git tag -a "$tag" -m "the x86-64-v3 closure of $NIXOS_REPO@$NIXOS_REV is in $RPI_CACHE_URL and cache.nixos.org" "$GITHUB_SHA"
                git push origin "refs/tags/$tag"
              fi
              # shellcheck disable=SC2016 # $names in the jq program are jq variables
              nix run .#ci-state -- "ci-state: $NIXOS_REPO@$NIXOS_REV fully cached" -- \
                --arg rev "$NIXOS_REV" --arg v3 "$GITHUB_SHA" --arg drv "$DRV" \
                '.cached = {nixos_rev: $rev, nixpkgs_v3_rev: $v3, toplevel_drv: $drv, store: env.RPI_CACHE_URL, at: (now | todate)}'
              echo "Fully cached: $NIXOS_REPO@$NIXOS_REV, tag $tag" >> "$GITHUB_STEP_SUMMARY"
            '';
          }
        ];
      };

      work = "steps.share.outputs.work == 'true'";
      build = {
        needs = "plan";
        if_ = "needs.plan.outputs.matrix != '[]' && needs.plan.outputs.matrix != ''";
        runsOn = "ubuntu-latest";
        timeoutMinutes = 355;
        permissions = {
          contents = "read";
          id-token = "write";
        };
        strategy = {
          failFast = false;
          matrix.machine = lib.range 0 (maxMachines - 1);
        };
        steps = [
          {
            name = "Does the plan give this runner work";
            id = "share";
            run = ''echo "work=''${{ contains(fromJSON(needs.plan.outputs.matrix), matrix.machine) }}" >> "$GITHUB_OUTPUT"'';
          }
        ]
        ++ map (step: { if_ = work; } // step) [
          {
            name = "Runner CPU must run x86-64-v3 code";
            run = ''
              grep -m1 'model name' /proc/cpuinfo | tee -a "$GITHUB_STEP_SUMMARY"
              for f in avx2 bmi1 bmi2 fma movbe abm f16c; do grep -qw "$f" /proc/cpuinfo || { echo "::error::CPU lacks $f"; exit 1; }; done
              /lib64/ld-linux-x86-64.so.2 --help | grep -q 'x86-64-v3 (supported' || { echo "::error::glibc says no x86-64-v3"; exit 1; }
            '';
          }
          reclaimDisk
          checkout
          (installNix builderConfig)
          (connectTailnet "${work} && ${rpiMode}")
          {
            name = "Setup Cachix";
            uses = actions.cachix;
            with_ = {
              name = "\${{ env.CACHE_NAME }}";
              authToken = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
              # With the RPi cache the executor pushes only shares; the daemon
              # would push every output into the 5 GB LRU.
              skipPush = "\${{ needs.plan.outputs.push != 'true' || needs.plan.outputs.mode == 'rpi' }}";
              pushFilter = "\${{ env.LOCAL_ONLY }}";
            };
          }
          {
            name = "Evaluate the same target";
            env = {
              NIXOS_REV = out "plan" "nixos_rev";
              DRV = out "plan" "drv";
            };
            run = ''
              drv=$(${evalTarget "$NIXOS_REV"})
              [ "$drv" = "$DRV" ] || { echo "::error::evaluated $drv, plan has $DRV"; exit 1; }
            '';
          }
          {
            name = "Download the plan";
            uses = actions.downloadArtifact;
            with_.name = "plan";
          }
          {
            name = "Build share \${{ matrix.machine }}";
            env = {
              MACHINE = "\${{ matrix.machine }}";
              PUSH = out "plan" "push";
              MODE = out "plan" "mode";
              CACHIX_AUTH_TOKEN = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
            };
            # 5 h 15 min from here (setup took about 10 min) leaves time for
            # pushes and the export upload before the 6 h job limit.
            run = ''
              nix build .#v3ci --out-link v3ci
              flags=(--jobs 2 --cores 4 --logs logs --results "results-$MACHINE.json")
              if [ "$PUSH" = true ]; then flags+=(--remote); else flags+=(--no-remote); fi
              if [ "$MODE" = rpi ]; then
                flags+=(--export "$RUNNER_TEMP/export" --local-only "$LOCAL_ONLY")
                [ "$PUSH" != true ] || flags+=(--share-cache "$CACHE_NAME")
              fi
              ./v3ci/bin/v3ci execute --plan plan.json --machine "$MACHINE" --deadline "$(( $(date +%s) + 18900 ))" "''${flags[@]}"
            '';
          }
          {
            name = "Upload results";
            if_ = "always() && ${work}";
            uses = actions.uploadArtifact;
            with_ = {
              name = "results-\${{ matrix.machine }}";
              path = "results-\${{ matrix.machine }}.json\nlogs/\n";
              retention-days = 14;
              if-no-files-found = "ignore";
            };
          }
          {
            name = "Upload exports for the RPi cache";
            if_ = "always() && ${work} && ${rpiMode}";
            uses = actions.uploadArtifact;
            with_ = {
              name = "export-\${{ matrix.machine }}";
              path = "\${{ runner.temp }}/export";
              # Kept a week: rpi-push of a later run takes them when the RPi
              # was unreachable for this one.
              retention-days = 7;
              compression-level = 0;
              if-no-files-found = "ignore";
            };
          }
        ];
      };

      rpiPush = {
        needs = [
          "plan"
          "build"
        ];
        if_ = "always() && needs.plan.result == 'success' && ${rpiMode} && needs.plan.outputs.rpi_up == 'true'";
        runsOn = "ubuntu-latest";
        timeoutMinutes = 340;
        # One upload stream to the RPi at any time, also across runs.
        concurrency = {
          group = "rpi-push";
          cancelInProgress = false;
        };
        permissions = {
          contents = "write";
          actions = "read";
          id-token = "write";
        };
        outputs = {
          pushed = "\${{ steps.push.outputs.pushed }}";
          carried = "\${{ steps.push.outputs.carried }}";
        };
        steps = [
          reclaimDisk
          checkoutFull
          (installNix builderConfig)
          (connectTailnet "always()")
          fetchState
          {
            name = "Download plan and exports";
            uses = actions.downloadArtifact;
            with_ = {
              path = "\${{ runner.temp }}/artifacts";
              pattern = "{plan,export-*}";
            };
          }
          {
            name = "Push to the RPi cache";
            id = "push";
            env = {
              NIX_CACHE_SIGNING_KEY = "\${{ secrets.NIX_CACHE_SIGNING_KEY }}";
              NIX_CACHE_PUSH_PASSWORD = "\${{ secrets.NIX_CACHE_PUSH_PASSWORD }}";
              GH_TOKEN = "\${{ github.token }}";
              RPI_LIMIT_RATE = "\${{ vars.RPI_LIMIT_RATE || '4M' }}";
            };
            run = ''
              nix build ./ci#packages.x86_64-linux.nix-cache-push --out-link nix-cache-push
              export PUSH_TOOL="$PWD/nix-cache-push/bin/nix-cache-push"
              export ARTIFACTS="$RUNNER_TEMP/artifacts" PLAN="$RUNNER_TEMP/artifacts/plan/plan.json"
              nix run .#ci-rpi-push
            '';
          }
          {
            name = "Record what still waits for the RPi";
            if_ = "always()";
            env = {
              PUSHED = "\${{ steps.push.outputs.pushed }}";
              UNPUSHED = "\${{ steps.push.outputs.unpushed }}";
              UP = "\${{ steps.push.outputs.up_mib_s }}";
              DOWN = "\${{ steps.push.outputs.down_mib_s }}";
            };
            run = ''
              # A push that never ran (failed earlier) leaves this run's exports pending.
              [ -n "$PUSHED" ] || UNPUSHED="$GITHUB_RUN_ID"
              # shellcheck disable=SC2016 # $names in the jq program are jq variables
              nix run .#ci-state -- "ci-state: rpi push of run $GITHUB_RUN_ID" -- \
                --arg unpushed "$UNPUSHED" --arg up "''${UP:-0}" --arg down "''${DOWN:-0}" \
                '.unpushed = ($unpushed | split(" ") | map(select(. != ""))) | .link = {up_mib_s: ($up | tonumber), down_mib_s: ($down | tonumber), at: (now | todate)}'
            '';
          }
        ];
      };

      finalize = {
        needs = [
          "plan"
          "build"
          "rpi-push"
        ];
        if_ = "always() && needs.plan.result == 'success' && (needs.plan.outputs.matrix != '[]' || ${rpiMode})";
        runsOn = "ubuntu-latest";
        permissions = {
          contents = "write";
          actions = "write";
        };
        steps = [
          checkoutFull
          (installNix "")
          fetchState
          {
            name = "Download plan and results";
            uses = actions.downloadArtifact;
            with_ = {
              path = "artifacts";
              pattern = "{plan,results-*}";
            };
          }
          {
            name = "Summarize";
            id = "fin";
            run = ''
              nix build .#v3ci --out-link v3ci
              ./v3ci/bin/v3ci finalize --plan artifacts/plan/plan.json --times "$RUNNER_TEMP/build-times.json" \
                artifacts/results-*/results-*.json > "$RUNNER_TEMP/run-status.json"
              echo "built=$(jq .built "$RUNNER_TEMP/run-status.json")" >> "$GITHUB_OUTPUT"
            '';
          }
          {
            name = "Record build times on ci-state";
            if_ = "needs.plan.outputs.push == 'true'";
            env = {
              NIXOS_REV = out "plan" "nixos_rev";
              CAPPED = out "plan" "capped";
              MODE = out "plan" "mode";
            };
            run = ''
              # shellcheck disable=SC2016 # $names in the jq program are jq variables
              nix run .#ci-state -- "ci-state: build times of run $GITHUB_RUN_ID" build-times.json="$RUNNER_TEMP/build-times.json" -- \
                --slurpfile run "$RUNNER_TEMP/run-status.json" --arg rev "$NIXOS_REV" --arg capped "$CAPPED" --arg mode "$MODE" \
                --arg url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
                '.last = ($run[0] + {nixos_rev: $rev, run: $url, mode: $mode})
                 | .cachix_v3_gib = ((.cachix_v3_gib // 0) + $run[0].cachix_gib)
                 | if $capped == "true" and $mode != "rpi" then .capped_rev = $rev else . end'
            '';
          }
          {
            name = "Dispatch the next run";
            # With the RPi cache only after a complete push: the next run
            # takes its inputs from there, and an incomplete push would make
            # it rebuild them. A run that only pushed earlier exports goes on.
            if_ = lib.concatStringsSep " && " [
              "needs.plan.outputs.push == 'true'"
              "needs.plan.outputs.capped != 'true'"
              "(steps.fin.outputs.built != '0' || needs.rpi-push.outputs.carried != '')"
              "(needs.plan.outputs.mode != 'rpi' || needs.rpi-push.outputs.pushed == 'true')"
            ];
            env = {
              GH_TOKEN = "\${{ github.token }}";
              NIXOS_REV = out "plan" "nixos_rev";
              CHAIN = "\${{ inputs.chain || '0' }}";
              MACHINES = "\${{ inputs.machines || '${toString maxMachines}' }}";
            };
            run = ''
              chain=$(( CHAIN + 1 ))
              if [ "$chain" -gt "$MAX_CHAIN" ]; then echo "chain limit $MAX_CHAIN reached" >> "$GITHUB_STEP_SUMMARY"; exit 0; fi
              gh workflow run build.yml --ref "$GITHUB_REF_NAME" -f nixos_ref="$NIXOS_REV" -f machines="$MACHINES" -f chain="$chain"
              echo "Dispatched run $chain of the chain" >> "$GITHUB_STEP_SUMMARY"
            '';
          }
        ];
      };

      cheapTriggers = {
        push.branches = [ "main" ];
        pullRequest = { };
        workflowDispatch = { };
      };

      # github-actions-nix writes workflow_dispatch inputs with their unset
      # fields as `type: null` and `options: null`, which GitHub and
      # actionlint reject (its converters.nix filters nulls of the trigger but
      # not of the inputs). Drop null values until it does.
      workflows = pkgs.runCommand "github-workflows-clean" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
        mkdir "$out"
        for f in ${config.githubActions.workflowsDir}/*.yml; do
          yq eval 'del(.. | select(. == null))' "$f" > "$out/$(basename "$f")"
        done
      '';
    in
    {
      packages = {
        github-actions = workflows;

        sync-github-actions = pkgs.writeShellApplication {
          name = "sync-github-actions";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.findutils
          ];
          text = ''
            workflows=${lib.escapeShellArg workflows}
            mkdir -p .github/workflows
            # Workflows no longer generated must not stay behind.
            find .github/workflows -name '*.yml' -delete
            cp -f "$workflows"/*.yml .github/workflows/
            chmod +w .github/workflows/*.yml
          '';
        };
      };

      githubActions = {
        enable = true;
        workflows = {
          lint = {
            name = "lint";
            on = cheapTriggers;
            permissions.contents = "read";
            jobs.lint = {
              runsOn = "ubuntu-latest";
              timeoutMinutes = 30;
              steps = [
                checkout
                (installNix "")
                {
                  name = "Lint and build the CI tools";
                  run = lib.concatStringsSep " " (
                    [ "nix build -L" ]
                    ++ map (c: ".#checks.x86_64-linux.${c}") [
                      "pre-commit"
                      "v3ci"
                      "isa-scan"
                      "ci-plan"
                      "ci-state"
                      "ci-rpi-push"
                    ]
                  );
                }
              ];
            };
          };

          eval = {
            name = "eval";
            on = cheapTriggers;
            permissions.contents = "read";
            jobs.eval = {
              runsOn = "ubuntu-latest";
              timeoutMinutes = 60;
              steps = [
                checkout
                (installNix v3Config)
                {
                  name = "Flake checks (evaluation only)";
                  run = "nix flake check --no-build --all-systems";
                }
                {
                  name = "Toolchain assertions";
                  run = "nix build .#checks.x86_64-linux.toolchain";
                }
                {
                  name = "World target";
                  env.NIXOS_REPO = nixosRepo;
                  run = ''
                    rev=$(git ls-remote "https://github.com/$NIXOS_REPO" refs/heads/master | cut -f1)
                    drv=$(${evalTarget "$rev"})
                    {
                      echo "$NIXOS_REPO@$rev v3 toplevel: \`$drv\`"
                      echo "derivations in the build closure: $(nix-store -qR "$drv" | grep -c '\.drv$')"
                    } >> "$GITHUB_STEP_SUMMARY"
                  '';
                }
                {
                  name = "RPi cache uploader";
                  run = "nix eval --raw ./ci#packages.x86_64-linux.nix-cache-push.drvPath";
                }
              ];
            };
          };

          build = {
            name = "build";
            on = {
              push = {
                branches = [ "main" ];
                paths = [
                  "flake.nix"
                  "flake.lock"
                  "modules/**"
                  "ci/**"
                ];
              };
              # Polls janusz-bit/nixos master; a run for an already cached
              # revision stops after the plan.
              schedule = [ { cron = "17 */4 * * *"; } ];
              workflowDispatch.inputs = {
                nixos_ref = {
                  description = "janusz-bit/nixos branch, tag or commit";
                  default = "master";
                };
                machines = {
                  description = "Runners for this run (at most ${toString maxMachines})";
                  default = toString maxMachines;
                };
                chain = {
                  description = "Re-dispatch counter (set by finalize)";
                  default = "0";
                };
              };
            };
            permissions.contents = "read";
            concurrency = {
              group = "world-build";
              cancelInProgress = false;
            };
            env = {
              NIXOS_REPO = nixosRepo;
              CACHE_NAME = cache.name;
              CACHE_URL = cache.url;
              RPI_CACHE_URL = rpiCache.url;
              MAX_CHAIN = "40";
              MAX_MACHINES = toString maxMachines;
              LOCAL_ONLY = localOnly;
            };
            jobs = {
              inherit
                plan
                marker
                build
                finalize
                ;
              rpi-push = rpiPush;
            };
          };

          proof = {
            name = "proof";
            on = {
              schedule = [ { cron = "43 5 * * *"; } ];
              workflowDispatch.inputs.nixos_ref = {
                description = "janusz-bit/nixos branch, tag or commit";
                default = "master";
              };
            };
            permissions = {
              contents = "read";
              id-token = "write";
            };
            jobs.proof = {
              runsOn = "ubuntu-latest";
              timeoutMinutes = 120;
              env.NIXOS_REPO = nixosRepo;
              steps = [
                {
                  name = "Runner CPU";
                  run = ''grep -m1 'model name' /proc/cpuinfo | tee -a "$GITHUB_STEP_SUMMARY"'';
                }
                checkout
                (installNix v3Config)
                (connectTailnet "always()")
                {
                  name = "Are the sample packages cached";
                  id = "ready";
                  run = ''
                    ref=''${{ inputs.nixos_ref || 'master' }}
                    rev=$(git ls-remote "https://github.com/$NIXOS_REPO" "$ref" "refs/heads/$ref" | head -1 | cut -f1)
                    flags="--override-input nixos github:$NIXOS_REPO/''${rev:-$ref}"
                    echo "flags=$flags" >> "$GITHUB_OUTPUT"
                    for attr in isa-proof bench; do
                      # shellcheck disable=SC2086 # $flags holds two arguments
                      drv=$(nix eval --raw "./ci#packages.x86_64-linux.$attr.drvPath" $flags)
                      # The proof derivations and their small helpers may build; v3 packages may not.
                      n=$(nix-store --realise --dry-run "$drv" 2>&1 \
                        | awk '/will be built/ {s=1; next} /will be fetched/ {s=0} s && /\/nix\/store/' \
                        | grep -vc -e nixpkgs-v3- -e '-bench\.py' -e hyperfine || true)
                      echo "$attr needs $n builds" | tee -a "$GITHUB_STEP_SUMMARY"
                      echo "$attr=$n" >> "$GITHUB_OUTPUT"
                    done
                  '';
                }
                {
                  name = "ELF scan";
                  if_ = "steps.ready.outputs.isa-proof == '0'";
                  run = ''
                    nix build -L ./ci#packages.x86_64-linux.isa-proof ''${{ steps.ready.outputs.flags }}
                    cat result/isa.md >> "$GITHUB_STEP_SUMMARY"
                  '';
                }
                {
                  name = "A/B benchmark";
                  if_ = "steps.ready.outputs.bench == '0'";
                  run = ''nix run ./ci#packages.x86_64-linux.bench ''${{ steps.ready.outputs.flags }} | tee -a "$GITHUB_STEP_SUMMARY"'';
                }
              ];
            };
          };
        };
      };
    };
}
