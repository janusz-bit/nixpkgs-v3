{
  description = "CI composition of nixpkgs-v3: the laptop of janusz-bit/nixos on x86-64-v3";

  # A separate flake so the root flake never gets a janusz-bit/nixos input
  # (that flake imports the root one; inputs in both directions are a lock
  # cycle). The workflows pass `--override-input nixos github:janusz-bit/nixos/<rev>`,
  # so the lock below is only the default for local use.
  inputs = {
    nixos.url = "github:janusz-bit/nixos";
    # The same follows as janusz-bit/nixos sets on its nixpkgs-v3 input.
    nixpkgs-v3 = {
      url = "path:..";
      inputs = {
        nixpkgs.follows = "nixos/nixpkgs";
        flake-parts.follows = "nixos/flake-parts";
        import-tree.follows = "nixos/import-tree";
        git-hooks-nix.follows = "nixos/git-hooks-nix";
        github-actions-nix.follows = "nixos/github-actions-nix";
      };
    };
  };

  outputs =
    { nixos, nixpkgs-v3, ... }:
    let
      inherit (nixos.inputs) nixpkgs;
      inherit (nixpkgs) lib;
      host = nixos.nixosConfigurations.nixos;

      # Once janusz-bit/nixos imports this module itself, its own lock decides
      # the module revision: that is the laptop's exact closure. Before, the
      # module of this checkout is added on top.
      importsModule = nixos.inputs ? nixpkgs-v3;
      v3Host =
        if importsModule then
          host
        else
          host.extendModules { modules = [ nixpkgs-v3.nixosModules.default ]; };

      generic = nixpkgs.legacyPackages.x86_64-linux;
      v3 = v3Host.pkgs;
      tools = nixpkgs-v3.packages.x86_64-linux;
    in
    {
      inherit importsModule;

      # The world build target and its baseline twin (feasibility numbers).
      v3 = v3Host.config.system.build.toplevel;
      generic = if importsModule then null else host.config.system.build.toplevel;

      # nix-cache-push of janusz-bit/nixos (hosts/nix-cache.nix): the RPi
      # cache's own push, reused rather than forked. The workflows run it from
      # this lock (no --override-input), so a branch of janusz-bit/nixos under
      # test cannot change the uploader.
      packages.x86_64-linux =
        import ./proof.nix {
          inherit lib generic v3;
          inherit (tools) isa-scan;
        }
        // {
          inherit (nixos.packages.x86_64-linux) nix-cache-push;
        };
    };
}
