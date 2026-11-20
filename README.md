# nixpkgs-v3

The whole NixOS userspace built for **x86-64-v3**, with the build flags of
the CachyOS v3 repositories, compiled on GitHub Actions and served from
cachix (`janusz-bit.cachix.org`). Made for the laptop of
[janusz-bit/nixos](https://github.com/janusz-bit/nixos) (host `nixos`,
i5-13450HX), but the module works for any x86-64-v3 NixOS host.

```nix
# flake.nix of the system
inputs.nixpkgs-v3.url = "github:janusz-bit/nixpkgs-v3";
inputs.nixpkgs-v3.inputs.nixpkgs.follows = "nixpkgs";
# host modules
modules = [ inputs.nixpkgs-v3.nixosModules.default ];
```

**Do not switch a host to it before the world is in the cache.** The cache
holds a revision only when the tag `cached/nixos-<rev>` exists (see
[Fully cached marker](#fully-cached-marker)); until then a rebuild compiles
thousands of packages locally.

## What it does

| Layer | File | Effect |
|---|---|---|
| Platform | `module.nix` | `nixpkgs.hostPlatform = { system = "x86_64-linux"; gcc.arch = "x86-64-v3"; gcc.tune = "generic"; }`: cc-wrapper adds `-march=x86-64-v3 -mtune=generic` to every gcc, g++, gfortran and clang call, gcc itself is configured `--with-arch=x86-64-v3`, every derivation requires the system feature `gccarch-x86-64-v3`. |
| Toolchains | `overlay/toolchain.nix` | nixpkgs has no v3 handling for Go or Rust: `GOAMD64=v3` is baked into every `go_1_N` (becomes the toolchain default), the rustc/rustdoc wrapper gets `-C target-cpu=x86-64-v3`. |
| CachyOS parity | `overlay/cachyos.nix`, `lib/parity.nix` | Per-package changes of the CachyOS-specific packages (python PGO, `-O3` for xz and sqlite); what is already equivalent or not ported, with reasons. |
| Fallbacks | `overlay/fallbacks.nix` | A few leaf applications, Haskell, .NET and firmware from the baseline set (cache.nixos.org), each with its reason. |
| Flags as data | `lib/flags.nix` | CachyOS v3 makepkg flags, verbatim from `CachyOS/docker-makepkg` (`docker-makepkg-v3/makepkg.conf`, `rust.conf`). |

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
| `GOAMD64=v3`, `-C target-cpu=x86-64-v3` | global | overlay/toolchain.nix |
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

### Cachix storage is the binding constraint

The free cachix plan holds 5 GB. One v3 world is at least 29 GB compressed,
realistically 40 to 60 GB (the lower bound misses half of the derivations),
and every nixpkgs bump produces a new world. LRU eviction on a cache that is
too small would evict paths of the build while it runs and make runners
rebuild them.

So the planner reads the repository variable `CACHIX_QUOTA_GB` (default 5)
and, while the estimated remaining world exceeds 80 % of it, builds one
bounded share (40 % of the quota) per run and stops the chain, with the
reason in the run summary. Source copies and vendored crates
(`-src`, `-vendor`, `-source`) are never pushed (rebuilt in seconds where
needed), and data without code (linux-firmware) comes from cache.nixos.org.

| cachix plan | holds |
|---|---|
| Free, 5 GB | the bootstrap and core libraries only; the chain stops itself |
| Starter, 50 GiB | about one world; a nixpkgs bump evicts the previous one while building the next |
| Standard, 250 GB | 4 to 5 generations: enough to keep the deployed world while the next one builds |

After upgrading, set `CACHIX_QUOTA_GB` (Settings, Secrets and variables,
Actions, Variables) to the plan size. Retention can stay LRU: what the laptop
runs is re-fetched and so kept warm.

## The world build (CI)

`.github/workflows/build.yml`, every 4 hours, on pushes here and by hand:

1. **plan**: resolves janusz-bit/nixos `master` (or `nixos_ref`), evaluates
   `ci#v3` (the laptop's `nixosConfigurations.nixos` with its own flake.lock;
   before janusz-bit/nixos imports this flake, the module of this checkout is
   added with `extendModules`), dry-runs it against the caches and reads the
   `.drv` files of everything missing. Trivial derivations are contracted
   away. The DAG is list-scheduled over up to 16 runners: critical path
   first, each node on the runner where it can start earliest, preferring
   the runner that builds its heaviest input; nodes that would end after
   5 h 15 min are deferred to the next run.
2. **build** (matrix, one job per runner): checks that the CPU runs v3 code,
   moves `/nix` to the larger `/mnt` disk, evaluates the same target (and
   fails if the drvPath differs from the plan), then builds its share in plan
   order, two builds at a time. An input that another runner builds is
   waited for until its outputs appear in cachix; the cachix daemon pushes
   every finished path immediately. Builds still running at the deadline are
   stopped before the 6 h job limit.
3. **finalize**: merges measured build times and NAR sizes into
   `build-times.json` on branch `ci-state`, writes built/failed/skipped
   counts and failure logs to the summary and dispatches the next run while
   the last one built something (at most 40 in a chain).
4. **marker**: when a plan finds nothing left to build, tags
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

Exit status 0: every non-trivial path of that revision's v3 laptop closure is
in `janusz-bit.cachix.org`; `update` substitutes it and builds only the
trivial derivations (seconds). A branch of janusz-bit/nixos gets its marker
when the build workflow is dispatched with `nixos_ref=<branch>`.

## Proof

`proof.yml` (daily and by hand) needs the sample packages in cachix and
otherwise stops with a notice:

- `ci#packages.x86_64-linux.isa-proof` scans zstd, xz, python3, libc.so.6,
  fish (Rust) and tailscaled (Go) of both builds with `isa-scan`
  (`tools/isa-scan.sh`: GNU ISA-level note, count of instructions that
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
  PGO for LLVM, LTO for nodejs, zlib-ng as zlib: listed in `lib/parity.nix`,
  not ported.

## Development

```sh
nix fmt                                  # nixfmt-tree
nix build .#checks.x86_64-linux.lint     # nixfmt, statix, deadnix, actionlint
nix build .#checks.x86_64-linux.toolchain  # evaluation-only assertions
nix eval --raw ./ci#v3.drvPath           # the world target (minutes)
```

The root flake has no janusz-bit/nixos input (that flake imports this one;
inputs in both directions are a lock cycle); the composition lives in
`ci/flake.nix`, whose `nixpkgs-v3` input is the relative path `..`.
