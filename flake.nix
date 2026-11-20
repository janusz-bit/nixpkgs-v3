{
  description = "NixOS userspace built for x86-64-v3 with CachyOS build parity";

  # Only for this flake's own tools and checks. The module and the overlay use
  # the nixpkgs of the system that imports them; consumers set
  # inputs.nixpkgs.follows so the lock holds one nixpkgs.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # No janusz-bit/nixos input here: that flake imports this one, and an input
  # in both directions is a lock cycle. The CI composition lives in ci/.
  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      flags = import ./lib/flags.nix;
    in
    {
      overlays.default = import ./overlay;
      nixosModules.default = ./module.nix;

      lib = {
        inherit flags;
        # The v3 package set of any nixpkgs source, the way the module builds
        # it (checks, benchmarks, ad-hoc `nix build`).
        pkgsV3 =
          nixpkgsSource: config:
          import nixpkgsSource {
            localSystem = {
              system = "x86_64-linux";
              gcc = {
                arch = flags.march;
                tune = flags.mtune;
              };
            };
            inherit config;
            overlays = [ self.overlays.default ];
          };
      };

      packages = forAllSystems (pkgs: import ./tools { inherit pkgs; });

      checks = forAllSystems (
        pkgs:
        import ./checks {
          inherit pkgs self;
          pkgsV3 = self.lib.pkgsV3 nixpkgs { };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
