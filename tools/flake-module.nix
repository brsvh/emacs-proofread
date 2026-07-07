{
  inputs,
  ...
}:
let
  inherit (inputs)
    infix
    nixpkgs
    ;
in
{
  imports = [
    infix.flakeModules.devshell
  ];

  perSystem =
    {
      config,
      lib,
      pkgs',
      projectRoot,
      system,
      ...
    }:
    {
      _module = {
        args = {
          pkgs' = import nixpkgs {
            inherit
              system
              ;

            overlays = [
              infix.overlays.default
            ];
          };

          projectRoot = ../.;
        };
      };

      devshells = {
        default = import ./devshells/default.nix {
          inherit
            inputs
            lib
            projectRoot
            ;

          pkgs = pkgs';
        };
      };

      formatter = import ./formatter.nix {
        inherit
          lib
          ;

        pkgs = pkgs';

        treefmtConfig =
          config.devshells.default.files.treefmt;
      };
    };
}
