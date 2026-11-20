# Generic fallbacks: packages taken from the baseline (x86-64) package set of
# the same nixpkgs revision instead of being rebuilt for v3, each with its
# reason in modules/_data/parity.nix. They come from cache.nixos.org, so they cost the
# world build nothing.
#
# Only three kinds qualify:
# - leaf applications that cannot build inside one 6 h job on a 4-vCPU
#   runner (Chromium-class) or are leaf processes anyway; their libraries come
#   from the generic set with them, so no generic library is loaded into a v3
#   process;
# - Haskell: GHC's native code generator ignores -march, so a v3 rebuild of
#   Haskell code is the same code built twice (hours of GHC and its packages).
#   Haskell programs are separate processes (pandoc, shellcheck) and mostly
#   build tools;
# - data without code (firmware), which v3 would only duplicate in cachix.
#
# The baseline set reuses this set's nixpkgs config (allowUnfree,
# cudaCapabilities, ...) but none of its overlays: a fallback is the plain
# nixpkgs package, as on cache.nixos.org.
_final: prev:
let
  generic = import prev.path {
    localSystem = {
      inherit (prev.stdenv.hostPlatform) system;
    };
    inherit (prev) config;
  };
in
{
  inherit (generic)
    # Chromium-class: 10+ h on 4 vCPUs.
    ungoogled-chromium
    electron_43
    electron_44
    electron_45
    # PGO + LTO build far beyond 6 h; the wrapper too, so its LD_LIBRARY_PATH
    # libraries are generic as well.
    firefox
    firefox-unwrapped
    # 5-7 h on 4 vCPUs.
    libreoffice-qt
    # Pulls qtwebengine through pyside6.
    freecad-qt6
    # .NET: RyuJIT emits code for the running CPU; the source-built SDK
    # behind it takes 3+ h.
    pinta
    # Firmware blobs: data, no code runs on the CPU; 2 GB in cachix for
    # nothing.
    linux-firmware
    # GHC ignores -march.
    haskell
    haskellPackages
    pandoc
    shellcheck
    shellcheck-minimal
    ;
}
