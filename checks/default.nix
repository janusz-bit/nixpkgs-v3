# Cheap checks (`nix flake check`, CI lint and eval): formatting and lints of
# this repository, the CI tools build, and evaluation-only assertions that the
# v3 package set gets what the overlay promises. Nothing here builds v3
# packages; the ELF and benchmark proofs that need them are in ci/.
{
  pkgs,
  pkgsV3,
  self,
}:
let
  inherit (pkgs) lib;
  flags = import ../lib/flags.nix;
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.gitTracked ../.;
  };

  lint =
    pkgs.runCommand "nixpkgs-v3-lint"
      {
        nativeBuildInputs = [
          pkgs.nixfmt-tree
          pkgs.statix
          pkgs.deadnix
          pkgs.actionlint
          pkgs.shellcheck
        ];
      }
      ''
        cd ${src}
        treefmt --ci --tree-root . --no-cache
        statix check .
        deadnix --fail --no-lambda-pattern-names .
        actionlint .github/workflows/*.yml
        touch $out
      '';

  # Evaluation only: forces the attributes, builds nothing of the v3 set.
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
      "a go_1_N of this nixpkgs lacks GOAMD64=${flags.goamd64}; add it to overlay/toolchain.nix";
    assert lib.assertMsg (lib.hasInfix "target-cpu=${flags.march}" pkgsV3.rustc.buildCommand)
      "rustc wrapper lacks -C target-cpu=${flags.march}";
    pkgs.runCommand "nixpkgs-v3-toolchain-eval" { } "touch $out";
in
{
  inherit lint;
  inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) v3ci isa-scan;
}
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 { inherit toolchain; }
