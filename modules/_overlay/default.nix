# The overlay of nixpkgs-v3: toolchain defaults (toolchain.nix), CachyOS
# per-package parity (cachyos.nix) and generic fallbacks (fallbacks.nix).
#
# It only makes sense on a package set whose hostPlatform has
# gcc.arch = "x86-64-v3" (the NixOS module sets both). On a baseline set it
# would still change go/rustc/zig and rebuild their users for no gain.
let
  flags = import ../_data/flags.nix;
in
final: prev:
let
  layers = [
    (import ./toolchain.nix flags)
    (import ./cachyos.nix flags)
    (import ./fallbacks.nix)
  ];
in
prev.lib.composeManyExtensions layers final prev
