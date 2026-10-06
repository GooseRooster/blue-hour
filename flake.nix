{
  description = "blue-hour — development tooling for building the BlueBuild Fedora image";

  # This flake is for *developing* this repository (building/generating recipes
  # and ISOs, booting the result in a VM). It is deliberately separate from the
  # Nix that ships inside the image itself; the image's Nix/Home Manager/Homebrew
  # stack is a recipe concern (see docs/port-plan.md).
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The BlueBuild CLI. Its flake exposes packages.<system>.bluebuild.
    # Pinned via flake.lock; bump with `nix flake update bluebuild`.
    #
    # Note: we intentionally do NOT force our nixpkgs on this input. The CLI
    # flake references lib.licenses.apsl20, which newer nixpkgs dropped, so
    # following our nixpkgs breaks evaluation. Its own pinned nixpkgs (locked
    # here) is the safer choice for a standalone tool.
    bluebuild.url = "github:blue-build/cli";
  };

  outputs =
    {
      self,
      nixpkgs,
      bluebuild,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (
        system:
        let
          bluebuild-cli = bluebuild.packages.${system}.bluebuild;
        in
        {
          bluebuild = bluebuild-cli;
          default = bluebuild-cli;
        }
      );

      apps = forAllSystems (system: {
        bluebuild = {
          type = "app";
          program = "${self.packages.${system}.bluebuild}/bin/bluebuild";
        };
        default = self.apps.${system}.bluebuild;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              self.packages.${system}.bluebuild
              just
              # Container engine + image tooling for `bluebuild build`/`generate-iso`.
              podman
              buildah
              skopeo
              cosign
              # VM testing.
              qemu
              xorriso
              # Recipe/YAML helpers.
              jq
              yq-go
              shellcheck
              nixfmt
            ];

            shellHook = ''
              echo "blue-hour dev shell"
              echo "  bluebuild: $(bluebuild --version 2>/dev/null || echo 'unavailable')"
              echo "  local builds need a container engine; on NixOS set virtualisation.podman.enable = true"
              echo "  run 'just' to list common tasks"
            '';
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
