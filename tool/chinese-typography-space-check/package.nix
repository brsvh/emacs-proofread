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
      (readFile ./chinese-typography-space-check.el);
in
writeTextFile {
  name = "chinese-typography-space-check";
  destination = "/bin/chinese-typography-space-check";
  executable = true;
  text = script;
}
