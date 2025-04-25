{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      defaultForEachSupportedSystem = (func:
        nixpkgs.lib.genAttrs supportedSystems (system: {
          default = func system;
        })
      );
    in
    {
      devShells = defaultForEachSupportedSystem
        (system:
          let
            pkgs = import nixpkgs {
              inherit system;
            };
          in
          pkgs.mkShell {
            packages = with pkgs; [
              zig_0_14
              zls
              python3
            ];
          }
        );
    };
}
