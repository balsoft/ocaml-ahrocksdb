{
  inputs = {
    opam-nix.url = "github:tweag/opam-nix";
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.follows = "opam-nix/nixpkgs";
  };
  outputs = { self, flake-utils, opam-nix, nixpkgs }@inputs:
    let package = "ahrocksdb";
    in flake-utils.lib.eachDefaultSystem (system: {
      legacyPackages = let
        pkgs = nixpkgs.legacyPackages.${system};
        on = opam-nix.lib.${system};
        scope = on.buildOpamProject { } package ./. { };
        overlay = self: super: {
          # Your overrides go here
          ahrocksdb = super.ahrocksdb.overrideAttrs
            (_: {
              ROCKSDB = "${pkgs.rocksdb}/include/rocksdb";
            });
        };
      in scope.overrideScope' overlay;

      defaultPackage = self.legacyPackages.${system}.${package};
    });
}
