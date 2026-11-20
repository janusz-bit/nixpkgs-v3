# Language toolchains that do not follow hostPlatform.gcc.arch on their own.
#
# cc-wrapper turns gcc.arch/gcc.tune into -march/-mtune for gcc, g++, gfortran
# and clang, but nixpkgs has no equivalent for Go (GOAMD64 defaults to v1) or
# Rust (rustc targets x86-64 baseline unless -C target-cpu is given).
# CachyOS sets GOAMD64=v3 and RUSTFLAGS="-C target-cpu=x86-64-v3" in its v3
# makepkg.conf; this overlay bakes the same defaults into the toolchains, so
# every buildGoModule and buildRustPackage picks them up without per-package
# changes.
#
# Check: `nix build .#checks.x86_64-linux.toolchain` (modules/checks.nix)
# asserts GOAMD64=v3 on every go_1_N and -C target-cpu in the rustc wrapper.
flags: _final: prev:
let
  # Go versions of the pinned nixpkgs, listed by hand: deriving them from
  # `builtins.attrNames prev` makes this overlay's attribute names depend on
  # the package set it extends (infinite recursion once another overlay's
  # names depend on `final`). checks.x86_64-linux.toolchain fails when
  # nixpkgs gains a go_1_N that is missing here.
  goVersions = [
    "go_1_26"
    "go_1_27"
  ];

  # GOAMD64 at toolchain build time becomes the default of the built go
  # (cmd/dist writes it into internal/buildcfg/zbootstrap.go).
  goV3 =
    name:
    prev.${name}.overrideAttrs (old: {
      env = old.env // {
        GOAMD64 = flags.goamd64;
      };
    });
in
prev.lib.genAttrs goVersions goV3
// {
  # The wrapper applies defaultArgs to host and build targets alike; for a
  # native v3 build both are the v3 machine, so build scripts may use v3 too.
  wrapRustcWith =
    args:
    (prev.wrapRustcWith args).overrideAttrs (old: {
      buildCommand = old.buildCommand + ''
        for prog in rustc rustdoc; do
          substituteInPlace "$out/bin/$prog" \
            --replace-fail 'extraBefore=(' 'extraBefore=(-C target-cpu=${flags.march} '
        done
      '';
    });
}
