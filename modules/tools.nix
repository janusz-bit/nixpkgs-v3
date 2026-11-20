# CI tools, built with this flake's (generic) nixpkgs: v3ci (planner,
# executor and status table of the distributed world build, _tools/v3ci.py)
# and isa-scan (GNU ISA note and count of x86-64-v3 instructions in ELF
# files, _tools/isa-scan.sh).
#
# Check: `nix run .#v3ci -- --help`; `nix run .#isa-scan -- $(nix build --print-out-paths nixpkgs#zstd)`.
_: {
  perSystem =
    { pkgs, ... }:
    {
      packages = {
        v3ci = pkgs.writers.writePython3Bin "v3ci" {
          # Long f-strings in the job summaries; line length carries no meaning here.
          flakeIgnore = [ "E501" ];
        } (builtins.readFile ./_tools/v3ci.py);

        isa-scan = pkgs.writeShellApplication {
          name = "isa-scan";
          runtimeInputs = [
            pkgs.binutils-unwrapped
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnugrep
            pkgs.gawk
          ];
          text = builtins.readFile ./_tools/isa-scan.sh;
        };
      };
    };
}
