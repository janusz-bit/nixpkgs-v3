# What the overlay does about each CachyOS-specific package (the cachyos-v3
# repository, built from CachyOS-PKGBUILDS) and about generic fallbacks, as
# data for docs/status.md (`nix run .#v3ci -- status`). _overlay/cachyos.nix
# and _overlay/fallbacks.nix implement the `ported` and `fallbacks` entries;
# keep the three in step.
#
# Keys are nixpkgs pnames; `cachyos` names the CachyOS package base when it
# differs.
{
  ported = {
    python3 = {
      cachyos = "python";
      what = "PGO (--enable-optimizations); nixpkgs already has --with-lto, -fno-semantic-interposition and CPython's default -O3";
    };
    xz = {
      what = "-O3 (CFLAGS instead of configure's -g -O2); CachyOS's PGO patch not ported";
    };
    sqlite = {
      what = "-O3 (CFLAGS instead of autosetup's -g -O2); CachyOS's PGO and thin LTO not ported";
    };
  };

  # Already what CachyOS does, or no counterpart is needed in nixpkgs.
  equivalent = {
    zstd = "nixpkgs builds with CMake Release (-O3); PGO (zstd-pgo) not ported";
    lz4 = "upstream Makefile defaults to -O3; PGO not ported";
    go = "GOAMD64=v3 baked into every go_1_N (overlay/toolchain.nix)";
    gcc = "configured --with-arch=x86-64-v3 --with-tune=generic by nixpkgs from hostPlatform";
    glibc = "built with -march=x86-64-v3, so it carries the x86-64-v3 ISA level note";
    binutils = "no codegen effect on the output of other packages";
    libtool = "build tool, no codegen effect";
    linux-headers = "headers only";
    nvidia-open = "kernel module of the CachyOS kernel set (nix-cachyos-kernel with its own nixpkgs, already v3); untouched";
  };

  notPorted = {
    bash = "PGO training run (CachyOS) not ported";
    llvm = "PGO + BOLT of clang/LLVM would multiply its 1-2 h build on a 4-vCPU runner";
    mesa = "CachyOS carries extra merge requests; not ported, mesa follows nixpkgs";
    nodejs = "--enable-lto doubles a 1 h build and needs more than 16 GB RAM with LTO";
    zlib-ng = "CachyOS replaces zlib with zlib-ng-compat; swapping zlib for the whole closure breaks version checks, left for later";
    openblas = "nixpkgs builds DYNAMIC_ARCH (runtime kernel selection), which already picks Haswell kernels";
    ripgrep = "PGO not ported";
    svt-av1 = "PGO not ported";
    sddm = "CachyOS theme and config patches; nixpkgs module configures SDDM";
    gamescope = "CachyOS patches not ported";
  };

  # Leaf applications taken from the generic package set. Only applications:
  # a library loaded into v3 processes must stay v3.
  fallbacks = {
    ungoogled-chromium = "Chromium: 10+ h on a 4-vCPU runner, cannot finish in one 6 h job; leaf application";
    electron = "electron_43/44/45 (Chromium-based runtime of heroic, element, signal, mullvad, joplin, vesktop, trilium, t3code): 10+ h each; the apps' own code and native modules stay v3";
    firefox = "nixpkgs builds Firefox with PGO and LTO, far beyond 6 h on 4 vCPUs; leaf application, wrapper included";
    libreoffice-qt = "5-7 h on 4 vCPUs; leaf application";
    freecad-qt6 = "pulls qtwebengine through pyside6; leaf application";
    pinta = ".NET application: RyuJIT emits code for the running CPU, and the source-built .NET SDK behind it takes 3+ h";
    linux-firmware = "firmware blobs, no CPU code; a v3 copy would only take 2 GB of cache";
    tzdata = "zone data; the v3 rebuild re-runs a wall-clock check (now.ck) that fails once the data ages past its build date";
    haskell = "haskellPackages, pandoc, shellcheck: GHC's code generator ignores -march, so v3 would rebuild identical code; separate processes and mostly build tools";
  };
}
