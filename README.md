# nixpkgs-v3

The whole NixOS userspace built for **x86-64-v3**, with the build flags of
the CachyOS v3 repositories, compiled on GitHub Actions and served from
the tailnet cache of janusz-bit/nixos on its Raspberry Pi (cachix only
carries what runners hand each other). Made for the laptop of
[janusz-bit/nixos](https://github.com/janusz-bit/nixos) (host `nixos`,
i5-13450HX), but the module works for any x86-64-v3 NixOS host.

```nix
# flake.nix of the system
inputs.nixpkgs-v3.url = "github:janusz-bit/nixpkgs-v3";
inputs.nixpkgs-v3.inputs.nixpkgs.follows = "nixpkgs"; # also flake-parts, import-tree, git-hooks-nix, github-actions-nix
# host modules
modules = [ inputs.nixpkgs-v3.nixosModules.default ];
```

**Do not switch a host to it before the world is in the cache.** The cache
holds a revision only when the tag `cached/nixos-<rev>` exists (see
[Fully cached marker](#fully-cached-marker)); until then a rebuild compiles
thousands of packages locally.

## What it does

The flake is built like janusz-bit/nixos: flake-parts plus import-tree, so
every `.nix` file under `modules/` is a flake-parts module and `_`-prefixed
paths (`modules/_data`, `_overlay`, `_tools`) hold what the modules load.
Consumers set `follows` for `nixpkgs`, `flake-parts`, `import-tree`,
`git-hooks-nix` and `github-actions-nix`.

| Layer | File | Effect |
|---|---|---|
| Platform | `modules/nixos.nix` (`nixosModules.default`) | `nixpkgs.hostPlatform = { system = "x86_64-linux"; gcc.arch = "x86-64-v3"; gcc.tune = "generic"; }`: cc-wrapper adds `-march=x86-64-v3 -mtune=generic` to every gcc, g++, gfortran and clang call, gcc itself is configured `--with-arch=x86-64-v3`, every derivation requires the system feature `gccarch-x86-64-v3`. |
| Toolchains | `modules/_overlay/toolchain.nix` | nixpkgs has no v3 handling for Go or Rust: `GOAMD64=v3` is baked into every `go_1_N` (becomes the toolchain default), the rustc/rustdoc wrapper gets `-C target-cpu=x86-64-v3`. |
| CachyOS parity | `modules/_overlay/cachyos.nix`, `modules/_data/parity.nix` | Per-package changes of the CachyOS-specific packages (python PGO, `-O3` for xz and sqlite); what is already equivalent or not ported, with reasons. |
| Fallbacks | `modules/_overlay/fallbacks.nix` | A few leaf applications, Haskell, .NET, firmware and tzdata from the baseline set (cache.nixos.org), each with its reason. |
| Flags as data | `modules/_data/flags.nix` (`lib.flags`) | CachyOS v3 makepkg flags, verbatim from `CachyOS/docker-makepkg` (`docker-makepkg-v3/makepkg.conf`, `rust.conf`). |

Prior art checked: nixpkgs has no `pkgsx86_64_v3` variant (only
`lib.systems.architectures` knows the levels). Chaotic-Nyx (an input of
janusz-bit/nixos) has `pkgsx86_64_v3`, a second package set with `gcc.arch`
alone: no Go or Rust handling, not in its cache, and a separate set would
mix two worlds in one system, so the module sets hostPlatform instead.
xddxdd/nix-cachyos-kernel covers the kernel only (the laptop already uses
it, built with its own nixpkgs, so this module leaves it alone). Grafting
(`replaceDependencies`) was rejected: it needs import-from-derivation.

### Flag parity

CachyOS v3 (`docker-makepkg-v3`, 2024-11-02):

```
CFLAGS="-march=x86-64-v3 -mtune=generic -O3 -pipe -fno-plt -fexceptions -Wp,-D_FORTIFY_SOURCE=3
        -Wformat -Werror=format-security -fstack-clash-protection -fcf-protection -mpclmul"
LDFLAGS="-Wl,-O1 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,-z,pack-relative-relocs"
LTOFLAGS="-flto=auto"   OPTIONS=(... lto ...)   GOAMD64=v3
RUSTFLAGS="-C opt-level=3 -C target-cpu=x86-64-v3 -Clink-arg=-z -Clink-arg=pack-relative-relocs"
```

| Flag | Here | Why |
|---|---|---|
| `-march=x86-64-v3 -mtune=generic` | global | hostPlatform `gcc.arch`/`gcc.tune` |
| `GOAMD64=v3`, `-C target-cpu=x86-64-v3` | global | modules/_overlay/toolchain.nix |
| `-O3` | per package | `NIX_CFLAGS_COMPILE` comes before a package's own flags, so a global `-O3` would lose to every `-O2` a build system adds and only change the packages that pick no level. Where it matters it is set per package (`CFLAGS=-O3`); CMake Release (zstd) and CPython already use `-O3`. |
| LTO (`-flto=auto`) | not global | LTO across the whole nixpkgs closure breaks static archives and doubles memory; nixpkgs already uses LTO where packages support it (CPython `--with-lto`, gcc, Firefox). |
| `-mpclmul` | not ported | Not part of any ISA level; the libraries that use PCLMULQDQ (zlib-ng, crc32 code in zstd/xz) dispatch at run time anyway, and adding it needs a replaced stdenv. |
| `-fno-plt`, `-z pack-relative-relocs`, `-O1 --sort-common` | not ported | Linker/startup details, no measurable runtime effect, would need a replaced stdenv for every package. |
| `_FORTIFY_SOURCE=3`, stack-clash | nixpkgs equivalent | nixpkgs default hardening (fortify, stack protector, stack-clash protection, format, relro, bindnow) |
| `-fcf-protection` (CET) | not ported | opt-in in nixpkgs (`shadowstack` hardening), not a codegen gain |
| `-C opt-level=3` | already | cargo `--release` uses opt-level 3. |

Per-package status for every CachyOS v3 package in the laptop closure:
[docs/status.md](docs/status.md) (`nix run .#v3ci -- status`).

## Feasibility

Measured on 2026-11-20 against janusz-bit/nixos `aa06df0` (nixpkgs
`0490633`, 2026-11-17).

| | |
|---|---|
| Laptop runtime closure today (live, generic) | 4,083 store paths, 50.6 GiB NAR |
| Laptop CPU | i5-13450HX: AVX2, BMI2, FMA, MOVBE, no AVX-512; glibc reports `x86-64-v3 (supported, searched)` |
| Derivations in the v3 build closure | 21,440 store derivations (generic: 16,535; 8,440 shared: sources, the CachyOS kernel set, inputs with their own nixpkgs) |
| Not substitutable, full v3 world without fallbacks | 6,340: 5,086 real builds + 1,254 trivial (etc files, units, wrappers) |
| Not substitutable with the fallbacks (first CI plan) | 6,689: 5,424 real + 1,265 trivial (the CI dry run also counts sources missing from cache.nixos.org) |
| NAR size of the generic twins on cache.nixos.org | **86.0 GB NAR, 29.2 GB compressed (xz)** for the 2,376 twins found; 2,267 more (unfree CUDA, local packages, bootstrap intermediates) are not on cache.nixos.org, so this is a lower bound |
| Estimated build time | ~480 runner-hours on 4-vCPU runners (~1,900 vCPU-hours), critical path ~35 h (heuristic estimates, replaced by measured times as runs finish) |
| 16 runners x 5 h 15 min per run | ~84 runner-hours per run: about 6 to 8 chained runs, 1.5 to 2 days of wall time for the first world |

Largest generic twins by NAR: clang 21 (3.95 GB), clang 20 (3.91 GB), .NET VMR
(2.9 + 2.8 GB), GHC (2.7 GB), vendored crates of codex and zed (2.3 + 2.1 GB),
linux-firmware (2.0 GB), LLVM sources (1.5 to 2.0 GB each), rustc (1.9 GB).

Derivations that cannot finish in one 6 h job on a 4-vCPU runner:
ungoogled-chromium, electron 43/44/45 (each a Chromium build), qtwebengine
(estimated 6 to 10 h), Firefox (nixpkgs builds it with PGO and LTO) and, close
to the limit, LibreOffice. All but qtwebengine are leaf applications and come
from the baseline set. qtwebengine is a library loaded into plasmashell
(kdeplasma-addons, plasma-nm), so it cannot be generic; the planner gives it
one attempt, and a timeout marks it "too big" in every later plan (see
[What remains](#what-remains)).

### Storage: the RPi cache, with cachix only between runners

One v3 world is at least 29 GB compressed, realistically 40 to 60 GB (the
lower bound misses half of the derivations), and every nixpkgs bump produces
a new one. The free cachix plan holds 5 GB and also carries the laptop's
CachyOS kernel, so it cannot be the store.

The durable store is the tailnet cache of janusz-bit/nixos on the RPi
(`hosts/nix-cache.nix` there): a plain binary cache behind nginx, 954 GB SSD
with about 747 GB free, reachable only in the tailnet at
`https://raspberry-pi-4.tail1ea20e.ts.net:8444`. CI signs (key
`janusz-bit-ci-1`, secret `NIX_CACHE_SIGNING_KEY`), the RPi only stores
files. That is room for 10 or more worlds; its `nix-cache-gc` drops entries
90 days after upload.

| store | what is in it | who writes |
|---|---|---|
| RPi cache | every v3 output of the laptop's closure, plus what the closure takes from cachix (CachyOS kernel and friends) | job `rpi-push`, one per run, one path at a time, rate-limited |
| cachix | only outputs that another runner of the same run waits for (`CACHIX_SHARE_GB`, default 1 GiB per run) | the builder that made it (`cachix push`) |
| cache.nixos.org | the generic fallbacks | Hydra |

How a run uses them:

- Every runner joins the tailnet as an ephemeral `tag:ci` node (OIDC,
  `tailscale/github-action`, as in janusz-bit/nixos) and has the RPi cache
  as its last substituter (`connect-timeout = 5`): inputs from earlier runs
  come from cachix if it still has them, else from the RPi.
- Builders export every finished output to a local binary cache directory
  (`v3ci execute --export`, stub narinfos for the references, the trick of
  janusz-bit/nixos `nix-cache-push`) and upload it as artifact `export-<n>`
  (kept 7 days).
- `rpi-push` (concurrency group `rpi-push`, so never two at once, also across
  runs) merges the exports, fetches what the plan found only in cachix
  (`.durable.repush`), probes the link (32 MiB up and down, numbers in the
  summary and in `ci-state:status.json` `.link`) and runs janusz-bit/nixos's
  own `nix-cache-push` (re-exported by `ci/flake.nix` from its lock),
  limited to `RPI_LIMIT_RATE` (default 4 MiB/s) through curl's config file.
  The RPi is on Wi-Fi, and four parallel large uploads have dropped it off
  the network for 12 minutes.
- If the RPi is unreachable or a push stops, the run's id goes to
  `.unpushed`; the next run builds nothing, pushes those exports first and
  only then continues the chain. While the RPi is down nothing is built, so
  no work is lost and nothing is rebuilt.
- Without the RPi secrets the build falls back to cachix alone: at most 40 %
  of `CACHIX_QUOTA_GB` (default 5) for the v3 world in all, counted over runs
  in `.cachix_v3_gib` (runs 2 to 4 used about 1 GiB), then it stops with the
  reason in the summary. No fully-cached marker in that mode.

Source copies and vendored crates (`-src`, `-vendor`, `-source`) are never
pushed (rebuilt in seconds where needed), and data without code
(linux-firmware, tzdata) comes from cache.nixos.org.

Not measured yet: how fast runners download from the RPi (the RPi's upload
over the home line and Tailscale). `rpi-push` records it on every run;
until it is known to be fast, cachix stays the first place runners look.

## The world build (CI)

`.github/workflows/build.yml` (generated from `modules/github-actions.nix`
with github-actions-nix, `nix run .#sync-github-actions`), every 4 hours, on
pushes here and by hand:

1. **plan**: resolves janusz-bit/nixos `master` (or `nixos_ref`), evaluates
   `ci#v3` (the laptop's `nixosConfigurations.nixos` with its own flake.lock;
   before janusz-bit/nixos imports this flake, the module of this checkout is
   added with `extendModules`), dry-runs it against the caches and reads the
   `.drv` files of everything missing. Trivial derivations are contracted
   away. The DAG is list-scheduled over up to 16 runners: critical path
   first, each node on the runner where it can start earliest, preferring
   the runner that builds its heaviest input; nodes that would end after
   5 h 15 min are deferred to the next run.
2. **build** (matrix of 16 runners; a runner without work in the plan skips
   its steps): checks that the CPU runs v3 code,
   moves `/nix` to the larger `/mnt` disk, evaluates the same target (and
   fails if the drvPath differs from the plan), then builds its share in plan
   order, two builds at a time. An input that another runner builds is
   waited for until its outputs appear in cachix, where the builder pushes
   exactly those shares (without the RPi cache, the cachix daemon pushes
   every finished path). Builds still running at the deadline are
   stopped before the 6 h job limit.
3. **rpi-push**: takes the run's exports to the RPi cache (see Storage).
4. **finalize**: merges measured build times and NAR sizes into
   `build-times.json` on branch `ci-state`, writes built/failed/skipped
   counts and failure logs to the summary and dispatches the next run while
   the last one built something and, with the RPi cache, its push completed
   (at most 40 in a chain).
5. **marker**: when the durable store lacks nothing, tags
   `cached/nixos-<rev>` and writes `ci-state:status.json`.

Without the `CACHIX_AUTH_TOKEN` secret everything still runs, on one runner
with a 2 h budget, without push and without re-dispatch. The jobs that hold
the token run only on push, schedule or dispatch in this repository, never
for pull requests. Actions are pinned to commit SHAs.

`lint.yml` (nixfmt, statix, deadnix, actionlint, flake8) and `eval.yml`
(flake checks, toolchain assertions, the world target) run on every push and
pull request.

### Fully cached marker

```sh
rev=$(git ls-remote https://github.com/janusz-bit/nixos refs/heads/master | cut -f1)
git ls-remote --exit-code https://github.com/janusz-bit/nixpkgs-v3 "refs/tags/cached/nixos-$rev"
```

Exit status 0: a machine with only cache.nixos.org and the RPi cache as
substituters builds nothing but the trivial derivations of that revision's
v3 laptop closure (the plan's second dry run, `--durable`). cachix is not
part of the promise. `update` on the laptop, which has the RPi cache as a
substituter, then substitutes everything. A branch of janusz-bit/nixos gets
its marker when the build workflow is dispatched with `nixos_ref=<branch>`.

## One-time steps (user)

On the laptop, which has the RPi cache secrets of janusz-bit/nixos:

1. Secrets on janusz-bit/nixpkgs-v3, the same values as on janusz-bit/nixos:
   `gh secret set NIX_CACHE_SIGNING_KEY --repo janusz-bit/nixpkgs-v3` and
   `gh secret set NIX_CACHE_PUSH_PASSWORD --repo janusz-bit/nixpkgs-v3`
   (both read from stdin, so nothing lands in the shell history).
2. Tailscale admin console, Trust credentials: an OpenID Connect credential
   for GitHub Actions with subject `repo:janusz-bit/nixpkgs-v3:*`, scope
   `auth_keys`, tag `tag:ci`; its client id and audience go to
   `TS_OAUTH_CLIENT_ID` and `TS_AUDIENCE` of this repository. The tailnet
   policy already lets `tag:ci` reach only `tcp:8444` on the RPi.
3. Optional repository variables: `RPI_LIMIT_RATE` (curl rate, default `4M`;
   lower it if the RPi drops off Wi-Fi during pushes), `CACHIX_SHARE_GB`
   (default 1), `RPI_QUOTA_GB` (default 600).
4. `gh workflow run build.yml --repo janusz-bit/nixpkgs-v3` starts the chain;
   the first run's `rpi-push` summary shows the measured link speeds.

## Proof

`proof.yml` (daily and by hand) needs the sample packages in cachix and
otherwise stops with a notice:

- `ci#packages.x86_64-linux.isa-proof` scans zstd, xz, python3, libc.so.6,
  fish (Rust) and tailscaled (Go) of both builds with `isa-scan`
  (`modules/_tools/isa-scan.sh`: GNU ISA-level note, count of instructions that
  x86-64-v2 lacks) and fails unless each v3 file is clearly v3;
- `ci#packages.x86_64-linux.bench` runs hyperfine A/B on the runner: zstd -19
  and decompression, xz -6 and decompression, a pure-Python workload,
  ffmpeg scaling and mpeg4 encoding.

Results: see [Measured results](#measured-results).

## Measured results

Filled in from the runs as they finish.

## What remains

- qtwebengine: if it times out on a 4-vCPU runner, the options are building
  `kdeplasma-addons` and `plasma-nm` without their WebEngine parts (the
  browser and dictionary plasmoids, OpenConnect SAML login) so qtwebengine
  stays only in leaf applications that can fall back, or a larger runner.
- CachyOS PGO for bash, zstd, xz, lz4, sqlite, ripgrep and svt-av1, BOLT and
  PGO for LLVM, LTO for nodejs, zlib-ng as zlib: listed in
  `modules/_data/parity.nix`, not ported.

## Development

```sh
nix develop                                   # installs the pre-commit hooks
nix fmt                                       # nixfmt-tree
nix build .#checks.x86_64-linux.pre-commit    # nixfmt, statix, deadnix, actionlint, workflows up to date
nix build .#checks.x86_64-linux.toolchain     # evaluation-only assertions
nix run .#sync-github-actions                 # regenerate .github/workflows
nix eval --raw ./ci#v3.drvPath                # the world target (minutes)
```

After a change of the root flake's inputs, run
`nix flake update nixpkgs-v3 --flake ./ci`: ci/flake.lock keeps the old
input list of the relative `..` input otherwise, and the world target fails
to evaluate (`attribute 'flake-parts' missing`).

The root flake has no janusz-bit/nixos input (that flake imports this one;
inputs in both directions are a lock cycle); the composition lives in
`ci/flake.nix`, whose `nixpkgs-v3` input is the relative path `..`.
