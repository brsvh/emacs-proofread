{
  pkgs,
  ...
}:
let
  releaseEmacs =
    (with pkgs; emacsPackagesFor emacs30)
    .emacsWithPackages
      (
        epkgs: with epkgs; [
          llm
          posframe
        ]
      );
in
{
  packages = with pkgs; [
    actionlint
    coreutils
    gh
    git
    gnumake
    gnutar
    jq
    releaseEmacs
    shellcheck
  ];
}
