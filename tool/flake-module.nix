{
  inputs,
  projectRoot,
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

        release = import ./devshells/release.nix {
          inherit
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
