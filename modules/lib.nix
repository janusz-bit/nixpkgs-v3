# flake.lib: the CachyOS v3 flags and the parity table as data (_data/),
# and pkgsV3, the v3 package set of any nixpkgs source built the way the
# NixOS module builds it (checks, benchmarks, ad-hoc `nix build`).
#
# Check: `nix eval --json .#lib.flags` and `nix eval --json .#lib.parity`.
{ config, ... }:
let
  flags = import ./_data/flags.nix;
in
{
  flake.lib = {
    inherit flags;
    parity = import ./_data/parity.nix;
    pkgsV3 =
      nixpkgsSource: nixpkgsConfig:
      import nixpkgsSource {
        localSystem = {
          system = "x86_64-linux";
          gcc = {
            arch = flags.march;
            tune = flags.mtune;
          };
        };
        config = nixpkgsConfig;
        overlays = [ config.flake.overlays.default ];
      };
  };
}
