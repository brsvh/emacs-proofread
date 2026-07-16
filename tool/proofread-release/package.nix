{
  coreutils,
  emacs,
  lib,
  writeTextFile,
}:
let
  inherit (lib)
    getExe
    getExe'
    readFile
    replaceStrings
    ;

  script =
    replaceStrings
      [
        "#!/usr/bin/env -S emacs --quick --script"
      ]
      [
        "#!${getExe' coreutils "env"} -S ${getExe emacs} --quick --script"
      ]
      (readFile ./proofread-release.el);
in
writeTextFile {
  name = "proofread-release";
  destination = "/bin/proofread-release";
  executable = true;
  text = script;
}
