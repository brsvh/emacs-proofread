{
  pkgs,
  projectRoot,
  ...
}:
let
  emacs =
    (with pkgs; emacsPackagesFor emacs31)
    .emacsWithPackages
      (
        epkgs: with epkgs; [
          llm
          posframe
        ]
      );

  proofreadRelease =
    pkgs.callPackage
      (
        projectRoot + /tool/proofread-release-wrapper.nix
      )
      {
        inherit
          emacs
          ;
      };
in
{
  packages = [
    emacs
  ]
  ++ (with pkgs; [
    actionlint
    coreutils
    gh
    git
    gnumake
    gnutar
    jq
    proofreadRelease
    shellcheck
  ]);
}
