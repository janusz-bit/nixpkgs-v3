# CachyOS per-package parity beyond the global flags, for packages of the
# cachyos-v3 repository that are in the laptop's closure (modules/_data/parity.nix
# lists what is ported, what is equivalent already and what is not, with the
# reason). Every entry here must build and pass its tests in the world build.
_flags: _final: prev:
let
  # Autotools-style configure scripts use CFLAGS instead of their default
  # "-g -O2" when it is set; cc-wrapper still adds -march/-mtune and the
  # hardening flags.
  withO3 =
    pkg:
    pkg.overrideAttrs (old: {
      env = (old.env or { }) // {
        CFLAGS = "-O3";
      };
    });

  # CachyOS python: --enable-optimizations (PGO). Not reproducible
  # bit-for-bit, which only matters to nixpkgs' reproducibility checks.
  withPgo = python: python.override { enableOptimizations = true; };
in
{
  python313 = withPgo prev.python313;
  python314 = withPgo prev.python314;
  xz = withO3 prev.xz;
  sqlite = withO3 prev.sqlite;
}
