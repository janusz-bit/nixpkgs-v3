# Skeleton of the flake: systems, flake-parts modules (git-hooks, github
# actions), formatter, pre-commit hooks (nixfmt, statix, deadnix, actionlint
# and the workflow generator) and the dev shell that installs them.
#
# Every .nix file under modules/ is a flake-parts module (import-tree);
# paths with a `_` segment are data and code the modules load (_data,
# _overlay, _tools) and are skipped.
#
# Check: `nix develop -c pre-commit run --all-files`; the same in CI:
# `nix build .#checks.x86_64-linux.pre-commit` (fails on stale generated
# workflows).
{ inputs, ... }:
{
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  imports = [
    inputs.git-hooks-nix.flakeModule
    inputs.github-actions-nix.flakeModules.default
  ];

  perSystem =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      formatter = pkgs.nixfmt-tree;

      pre-commit.settings.hooks = {
        nixfmt.enable = true;
        statix.enable = true;
        deadnix.enable = true;
        deadnix.settings.noLambdaPatternNames = true;
        actionlint.enable = true;
        # As in janusz-bit/nixos: `nix run` on the working tree, because the
        # hook entry is pinned to the store path of shell entry and would
        # regenerate stale workflows; the sandboxed check (no nix) uses the
        # pinned copy of the same commit.
        sync-github-actions = {
          enable = true;
          entry = lib.getExe (
            pkgs.writeShellApplication {
              name = "sync-github-actions-hook";
              text = ''
                if command -v nix >/dev/null; then
                  exec nix run .#sync-github-actions
                fi
                exec ${lib.getExe config.packages.sync-github-actions}
              '';
            }
          );
          always_run = true;
          pass_filenames = false;
        };
      };

      devShells.default = pkgs.mkShell {
        shellHook = config.pre-commit.installationScript;
        packages = config.pre-commit.settings.enabledPackages ++ [ config.packages.v3ci ];
      };
    };
}
