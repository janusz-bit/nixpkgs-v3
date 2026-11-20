# GitHub Actions workflows, generated with github-actions-nix as in
# janusz-bit/nixos: `nix run .#sync-github-actions` (also a pre-commit hook)
# rewrites .github/workflows/ and removes workflows that are gone.
#
# - lint: pre-commit check (nixfmt, statix, deadnix, actionlint, generated
#   workflows up to date) and the CI tools build (flake8 on v3ci).
# - eval: flake checks, toolchain assertions and the world target.
# - build: the world build. plan evaluates the laptop of janusz-bit/nixos on
#   x86-64-v3 (ci#v3), dry-runs it against the caches and list-schedules what
#   is missing over up to 16 runners (_tools/v3ci.py plan); build runs one
#   share per runner, waiting for inputs that other runners push to cachix;
#   finalize records measured times on branch ci-state and dispatches the
#   next run while progress is made; marker tags cached/nixos-<rev> once
#   nothing is left. Without CACHIX_AUTH_TOKEN it runs on one runner for 2 h
#   without push or re-dispatch. Never for pull requests: the jobs hold the
#   token.
# - proof: ELF scan and A/B benchmark, once the sample packages are cached.
#
# The matrix is static (machine 0..15): github-actions-nix types matrix
# values as lists, so a fromJSON matrix is not expressible. A runner the plan
# leaves without work skips its steps after the first.
#
# Actions are pinned to commit SHAs (tag in the comment): tags can move, and
# the build jobs see the cachix token and, in finalize and marker,
# `contents: write`. New SHA:
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
      };

      cache = {
        name = "janusz-bit";
        url = "https://janusz-bit.cachix.org";
        pubKey = "janusz-bit.cachix.org-1:4stTiufAF02BAXw8HNvYslAmUlPbZPIRhIGht0gSMoo=";
      };
      nixosRepo = "janusz-bit/nixos";
      maxMachines = 16;
      # Cheap intermediates (source copies, vendored crates): never pushed
      # (cachix pushFilter) and rebuilt by whichever runner needs them.
      localOnly = "(-src|-vendor|-source)(-[0-9][^-]*)?$";

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
      v3Config = ''
        extra-substituters = ${cache.url}
        extra-trusted-public-keys = ${cache.pubKey}
        extra-system-features = gccarch-x86-64 gccarch-x86-64-v2 gccarch-x86-64-v3
      '';
      # Negative narinfo answers must not be cached: a path another runner
      # pushes a minute later has to be seen at once.
      builderConfig = v3Config + ''
        narinfo-cache-negative-ttl = 0
      '';

      gitBot = ''
        git config user.name "github-actions[bot]"
        git config user.email "github-actions[bot]@users.noreply.github.com"
      '';
      checkoutState = ''
        if git fetch origin ci-state; then git checkout -B ci-state FETCH_HEAD; else git checkout --orphan ci-state && git rm -rqf --cached .; fi
      '';
      fetchTimes = "git fetch --depth=1 origin ci-state && git show FETCH_HEAD:build-times.json > build-times.json || echo '{}' > build-times.json";
      fetchState = "git fetch --depth=1 origin ci-state && git show FETCH_HEAD:status.json > state.json || echo '{}' > state.json";
      evalTarget =
        rev: "nix eval --raw ./ci#v3.drvPath --override-input nixos \"github:$NIXOS_REPO/${rev}\"";

      plan = {
        runsOn = "ubuntu-latest";
        timeoutMinutes = 90;
        outputs = {
          matrix = "\${{ steps.plan.outputs.matrix }}";
          real = "\${{ steps.plan.outputs.real }}";
          capped = "\${{ steps.plan.outputs.capped }}";
          nixos_rev = "\${{ steps.rev.outputs.nixos_rev }}";
          drv = "\${{ steps.eval.outputs.drv }}";
          push = "\${{ steps.secret.outputs.push }}";
        };
        steps = [
          checkout
          {
            name = "Is the cachix token set";
            id = "secret";
            env.CACHIX_AUTH_TOKEN = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
            run = ''if [ -n "$CACHIX_AUTH_TOKEN" ]; then echo push=true; else echo push=false; fi >> "$GITHUB_OUTPUT"'';
          }
          (installNix v3Config)
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
          {
            name = "Fetch measured build times and state";
            run = fetchTimes + "\n" + fetchState;
          }
          {
            name = "Plan";
            id = "plan";
            run = ''
              if [ "''${{ steps.secret.outputs.push }}" = true ]; then
                machines=''${{ inputs.machines || '${toString maxMachines}' }}; budget=18900
              else
                machines=1; budget=7200
              fi
              [ "$machines" -le ${toString maxMachines} ] || machines=${toString maxMachines}
              generic=$(nix eval --raw ./ci#generic.drvPath --override-input nixos "github:$NIXOS_REPO/''${{ steps.rev.outputs.nixos_rev }}" 2>/dev/null || true)
              nix run .#v3ci -- plan --drv "''${{ steps.eval.outputs.drv }}" --cache "$CACHE_URL" \
                --machines "$machines" --budget "$budget" --times build-times.json --out plan.json \
                --quota-gb "''${{ vars.CACHIX_QUOTA_GB || '5' }}" --local-only "$LOCAL_ONLY" ''${generic:+--generic "$generic"} > plan-out.json
              matrix=$(jq -c .matrix plan-out.json)
              # A cache too small for the world gets one bounded share per
              # janusz-bit/nixos revision; repeating it every schedule would
              # make LRU evict the previous shares.
              if [ "$(jq .capped plan-out.json)" = true ] && [ "$(jq -r '.capped_rev // ""' state.json)" = "''${{ steps.rev.outputs.nixos_rev }}" ]; then
                matrix='[]'
                echo "Cache quota too small and this revision already got its share: nothing built." >> "$GITHUB_STEP_SUMMARY"
              fi
              {
                echo "matrix=$matrix"
                echo "real=$(jq .real plan-out.json)"
                echo "capped=$(jq .capped plan-out.json)"
              } >> "$GITHUB_OUTPUT"
            '';
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
        if_ = "needs.plan.outputs.real == '0' && needs.plan.outputs.push == 'true'";
        runsOn = "ubuntu-latest";
        permissions.contents = "write";
        steps = [
          checkoutFull
          {
            name = "Publish the fully-cached marker";
            run = ''
              rev=''${{ needs.plan.outputs.nixos_rev }}
              tag="cached/nixos-$rev"
              ${gitBot}
              if ! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
                git tag -a "$tag" -m "every non-trivial path of $NIXOS_REPO@$rev (x86-64-v3) is in $CACHE_URL" "$GITHUB_SHA"
                git push origin "refs/tags/$tag"
              fi
              ${checkoutState}
              old=$(git show HEAD:status.json 2>/dev/null || echo '{}')
              jq --arg rev "$rev" --arg v3 "$GITHUB_SHA" --arg drv "''${{ needs.plan.outputs.drv }}" \
                '.cached = {nixos_rev: $rev, nixpkgs_v3_rev: $v3, toplevel_drv: $drv, at: (now | todate)}' <<<"$old" > status.json
              git add status.json && git commit -qm "ci-state: $NIXOS_REPO@$rev fully cached" && git push origin ci-state
              echo "Fully cached: $NIXOS_REPO@$rev, tag $tag" >> "$GITHUB_STEP_SUMMARY"
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
          {
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
          }
          checkout
          (installNix (
            builderConfig
            + ''
              build-dir = /nix/var/nix/builds
              max-silent-time = 3600
            ''
          ))
          {
            name = "Setup Cachix";
            uses = actions.cachix;
            with_ = {
              name = "\${{ env.CACHE_NAME }}";
              authToken = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
              skipPush = "\${{ needs.plan.outputs.push != 'true' }}";
              pushFilter = "\${{ env.LOCAL_ONLY }}";
            };
          }
          {
            name = "Evaluate the same target";
            run = ''
              drv=$(${evalTarget "\${{ needs.plan.outputs.nixos_rev }}"})
              [ "$drv" = "''${{ needs.plan.outputs.drv }}" ] || { echo "::error::evaluated $drv, plan has ''${{ needs.plan.outputs.drv }}"; exit 1; }
            '';
          }
          {
            name = "Download the plan";
            uses = actions.downloadArtifact;
            with_.name = "plan";
          }
          {
            name = "Build share \${{ matrix.machine }}";
            # 5 h 15 min from here (setup took about 10 min) leaves time for
            # the cachix daemon to finish pushing before the 6 h job limit.
            run = ''
              nix build .#v3ci --out-link v3ci
              deadline=$(( $(date +%s) + 18900 ))
              ./v3ci/bin/v3ci execute --plan plan.json --machine ''${{ matrix.machine }} --deadline "$deadline" \
                --jobs 2 --cores 4 ''${{ needs.plan.outputs.push == 'true' && '--remote' || '--no-remote' }} \
                --logs logs --results results-''${{ matrix.machine }}.json
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
        ];
      };

      finalize = {
        needs = [
          "plan"
          "build"
        ];
        if_ = "always() && needs.plan.result == 'success' && needs.plan.outputs.matrix != '[]'";
        runsOn = "ubuntu-latest";
        permissions = {
          contents = "write";
          actions = "write";
        };
        steps = [
          checkoutFull
          (installNix "")
          {
            name = "Download plan and results";
            uses = actions.downloadArtifact;
            with_.path = "artifacts";
          }
          {
            name = "Summarize";
            id = "fin";
            run = ''
              nix build .#v3ci --out-link v3ci
              ${fetchTimes}
              ./v3ci/bin/v3ci finalize --plan artifacts/plan/plan.json --times build-times.json \
                artifacts/results-*/results-*.json > status.json
              echo "built=$(jq .built status.json)" >> "$GITHUB_OUTPUT"
            '';
          }
          {
            name = "Record build times on ci-state";
            if_ = "needs.plan.outputs.push == 'true'";
            run = ''
              cp build-times.json status.json "$RUNNER_TEMP/"
              ${gitBot}
              ${checkoutState}
              cp "$RUNNER_TEMP/build-times.json" build-times.json
              jq --arg rev "''${{ needs.plan.outputs.nixos_rev }}" --arg run "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
                --arg capped "''${{ needs.plan.outputs.capped }}" \
                '.last = (input | . + {nixos_rev: $rev, run: $run}) | if $capped == "true" then .capped_rev = $rev else . end' \
                <(git show HEAD:status.json 2>/dev/null || echo '{}') "$RUNNER_TEMP/status.json" > status.json
              git add build-times.json status.json
              git commit -qm "ci-state: build times of run $GITHUB_RUN_ID" && git push origin ci-state
            '';
          }
          {
            name = "Dispatch the next run";
            if_ = "needs.plan.outputs.push == 'true' && needs.plan.outputs.capped != 'true' && steps.fin.outputs.built != '0'";
            env.GH_TOKEN = "\${{ github.token }}";
            run = ''
              chain=$(( ''${{ inputs.chain || '0' }} + 1 ))
              if [ "$chain" -gt "$MAX_CHAIN" ]; then echo "chain limit $MAX_CHAIN reached" >> "$GITHUB_STEP_SUMMARY"; exit 0; fi
              gh workflow run build.yml --ref "$GITHUB_REF_NAME" -f nixos_ref="''${{ needs.plan.outputs.nixos_rev }}" \
                -f machines="''${{ inputs.machines || '${toString maxMachines}' }}" -f chain="$chain"
              echo "Dispatched run $chain of the chain" >> "$GITHUB_STEP_SUMMARY"
            '';
          }
        ];
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

      cheapTriggers = {
        push.branches = [ "main" ];
        pullRequest = { };
        workflowDispatch = { };
      };
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
                  run = "nix build -L .#checks.x86_64-linux.pre-commit .#checks.x86_64-linux.v3ci .#checks.x86_64-linux.isa-scan";
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
              MAX_CHAIN = "40";
              LOCAL_ONLY = localOnly;
            };
            jobs = {
              inherit
                plan
                marker
                build
                finalize
                ;
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
            permissions.contents = "read";
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
