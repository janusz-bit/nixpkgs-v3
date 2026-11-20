# CI tools of this repository, built with the generic nixpkgs of the flake:
# v3ci (planner and executor of the distributed build, v3ci.py) and isa-scan
# (counts x86-64-v3 instructions and reads the GNU ISA note of ELF files).
{ pkgs }:
{
  v3ci = pkgs.writers.writePython3Bin "v3ci" {
    # Long f-strings in the job summaries; line length carries no meaning here.
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./v3ci.py);

  isa-scan = pkgs.writeShellApplication {
    name = "isa-scan";
    runtimeInputs = [
      pkgs.binutils-unwrapped
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gawk
    ];
    text = builtins.readFile ./isa-scan.sh;
  };
}
