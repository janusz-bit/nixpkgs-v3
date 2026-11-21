# CI tools, built with this flake's (generic) nixpkgs: v3ci (planner,
# executor and status table of the distributed world build, _tools/v3ci.py),
# isa-scan (GNU ISA note and count of x86-64-v3 instructions in ELF files,
# _tools/isa-scan.sh) and the longer steps of the build workflow (ci-plan,
# ci-rpi-push, ci-state; _tools/ci-*.sh, headers there). nix and nix-store
# come from the runner, the Nix the workflow installs.
#
# Check: `nix run .#v3ci -- --help`; `nix run .#isa-scan -- $(nix build --print-out-paths nixpkgs#zstd)`.
_: {
  perSystem =
    { config, pkgs, ... }:
    {
      packages = {
        v3ci = pkgs.writers.writePython3Bin "v3ci" {
          # Long f-strings in the job summaries; line length carries no meaning here.
          flakeIgnore = [ "E501" ];
        } (builtins.readFile ./_tools/v3ci.py);

        ci-plan = pkgs.writeShellApplication {
          name = "ci-plan";
          runtimeInputs = [
            config.packages.v3ci
            pkgs.jq
            pkgs.coreutils
          ];
          text = builtins.readFile ./_tools/ci-plan.sh;
        };

        ci-state = pkgs.writeShellApplication {
          name = "ci-state";
          runtimeInputs = [
            pkgs.git
            pkgs.jq
            pkgs.coreutils
          ];
          text = builtins.readFile ./_tools/ci-state.sh;
        };

        ci-rpi-push = pkgs.writeShellApplication {
          name = "ci-rpi-push";
          runtimeInputs = [
            pkgs.jq
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.gawk
            pkgs.findutils
            pkgs.curl
            pkgs.gh
          ];
          text = builtins.readFile ./_tools/ci-rpi-push.sh;
        };

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
