{
  description = "term: pinned apps for session automation tests";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
      # Real-app matrix for `term auto` real runs and golden snapshots
      # (docs: ~/brain/projects/term.md "Session automation"). Pinned by flake.lock
      # so recorded snapshots match the app versions that produced them.
      devShells = forAll (pkgs: {
        automation = pkgs.mkShell {
          packages = with pkgs; [
            fzf lazygit yazi btop htop
            vim neovim nano less
            dialog gum
            sqlite ruby bun
            eza git
            (python3.withPackages (ps: [ ps.textual ]))
          ];
        };
      });
    };
}
