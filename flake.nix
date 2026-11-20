{
  description = "NixOS userspace built for x86-64-v3 with CachyOS build parity";

  # Consumers make all of these follow their own copies (janusz-bit/nixos:
  # nixpkgs, flake-parts, import-tree, git-hooks-nix, github-actions-nix).
  # The module and the overlay use the nixpkgs of the system that imports
  # them; this flake's nixpkgs only builds its own tools and checks.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    import-tree.url = "github:vic/import-tree";
    git-hooks-nix.url = "github:cachix/git-hooks.nix";
    git-hooks-nix.inputs.nixpkgs.follows = "nixpkgs";
    github-actions-nix.url = "github:synapdeck/github-actions-nix";
    github-actions-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  # No janusz-bit/nixos input: that flake imports this one, and inputs in
  # both directions are a lock cycle. The CI composition is the subflake ci/.
  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);
}
