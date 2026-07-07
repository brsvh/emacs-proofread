{
  lib,
  pkgs,
  treefmtConfig,
}:
let
  inherit (lib)
    makeBinPath
    ;

  inherit (pkgs)
    treefmt
    writeShellScriptBin
    ;

  inherit (treefmtConfig)
    file
    packages
    ;
in
writeShellScriptBin "treefmt" ''
  set -euo pipefail
  export PATH=${makeBinPath packages}
  exec ${treefmt}/bin/treefmt \
    --config-file=${file} \
    --tree-root-file=flake.nix \
    "$@"
''
