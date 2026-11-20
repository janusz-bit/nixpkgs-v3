# NixOS module of nixpkgs-v3 (flake.nixosModules.default): the whole
# userspace built for x86-64-v3 with CachyOS v3 flags (-march=x86-64-v3
# -mtune=generic, GOAMD64=v3, Rust target-cpu=x86-64-v3) plus the overlay
# (toolchains, CachyOS parity, generic fallbacks). Nothing of it is on
# cache.nixos.org: the closure comes from the CI of this repository through
# cachix; README.md says when a host may switch.
#
# nixpkgs adds the system feature gccarch-x86-64-v3 to every derivation of
# such a set and NixOS adds it to nix.settings.system-features, so only
# machines with that feature (AVX2 CPU) build them.
#
# Check: `nix eval .#nixosConfigurations.<host>.pkgs.stdenv.hostPlatform.gcc`
# of a host importing it prints { arch = "x86-64-v3"; tune = "generic"; }.
{ config, ... }:
let
  flags = import ./_data/flags.nix;
  overlay = config.flake.overlays.default;
in
{
  flake.nixosModules.default =
    { config, lib, ... }:
    {
      # Keyed, so importing it twice (directly and through another flake)
      # keeps one overlay instead of applying it twice.
      key = "github:janusz-bit/nixpkgs-v3#nixosModules.default";

      config = {
        # Priority 90 beats the plain `nixpkgs.hostPlatform = "x86_64-linux"`
        # that nixosSystem callers and nixos-facter usually set (a string and
        # an attribute set at equal priority conflict), and still yields to
        # mkForce, which the assertion below then reports.
        nixpkgs.hostPlatform = lib.mkOverride 90 {
          system = "x86_64-linux";
          gcc = {
            arch = flags.march;
            tune = flags.mtune;
          };
        };
        nixpkgs.overlays = [ overlay ];

        assertions = [
          {
            assertion = (config.nixpkgs.hostPlatform.gcc.arch or null) == flags.march;
            message = "nixpkgs-v3: nixpkgs.hostPlatform is forced elsewhere without gcc.arch = \"${flags.march}\"; drop that definition or this module.";
          }
        ];
      };
    };
}
