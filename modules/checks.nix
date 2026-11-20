# Cheap checks beside checks.<system>.pre-commit (formatting, lints and
# generated workflows, modules/default.nix): the CI tools build (flake8 on
# v3ci) and, on x86_64, evaluation-only assertions that the v3 package set
# gets what the overlay promises. Nothing here builds v3 packages; the ELF
# and benchmark proofs that need them are in ci/.
#
# Check: `nix build .#checks.x86_64-linux.toolchain` (evaluates, builds a stamp).
{ config, inputs, ... }:
let
  flags = import ./_data/flags.nix;
  pkgsV3 = config.flake.lib.pkgsV3 inputs.nixpkgs { };
in
{
  perSystem =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      goNames = lib.filter (n: builtins.match "go_1_[0-9]+" n != null) (builtins.attrNames pkgsV3);
      goOk = lib.all (
        n:
        let
          r = builtins.tryEval pkgsV3.${n};
        in
        !r.success || !lib.isDerivation r.value || (r.value.GOAMD64 or null) == flags.goamd64
      ) goNames;
      toolchain =
        assert lib.assertMsg (
          pkgsV3.stdenv.hostPlatform.gcc.arch == flags.march
        ) "pkgsV3 is not ${flags.march}";
        assert lib.assertMsg goOk
          "a go_1_N of this nixpkgs lacks GOAMD64=${flags.goamd64}; add it to modules/_overlay/toolchain.nix";
        assert lib.assertMsg (lib.hasInfix "target-cpu=${flags.march}" pkgsV3.rustc.buildCommand)
          "rustc wrapper lacks -C target-cpu=${flags.march}";
        assert lib.assertMsg (lib.elem "--enable-optimizations" pkgsV3.python3.configureFlags)
          "python3 is built without PGO";
        pkgs.runCommand "nixpkgs-v3-toolchain-eval" { } "touch $out";
    in
    {
      checks = {
        inherit (config.packages) v3ci isa-scan;
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 { inherit toolchain; };
    };
}
