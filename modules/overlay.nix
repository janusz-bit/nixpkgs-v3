# The overlay (_overlay/): toolchain defaults, CachyOS per-package parity and
# generic fallbacks. Only meaningful on a package set whose hostPlatform has
# gcc.arch = "x86-64-v3"; the NixOS module (nixos.nix) sets both.
#
# Check: `nix eval .#overlays --apply builtins.attrNames`.
_: {
  flake.overlays.default = import ./_overlay;
}
