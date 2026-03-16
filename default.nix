{
  nixpkgs ? <nixpkgs>,
  pkgs ? import nixpkgs {},
  system ? builtins.currentSystem,
}: let
  inherit (pkgs) lib;
  sources = builtins.fromJSON (lib.strings.fileContents ./sources.json);
  mirrors = builtins.fromJSON (lib.strings.fileContents ./mirrors.json);

  # mkBinaryInstall makes a derivation that installs Zig from a binary.
  mkBinaryInstall = {
    url,
    version,
    sha256,
    platforms,
  }: let
    tarballName = lib.lists.last (lib.strings.split "/" url);
    srcIsFromZigLang = lib.strings.hasPrefix "https://ziglang.org/" url;
    urlFromMirrors =
      builtins.map
      (mirror: "${mirror}/${tarballName}?source=nix-zig-overlay")
      mirrors;
    urls =
      if srcIsFromZigLang
      then urlFromMirrors ++ [url]
      else [url];
  in
    pkgs.stdenv.mkDerivation (finalAttrs: {
      inherit version;

      pname = "zig";
      src = pkgs.fetchurl {inherit urls sha256;};
      strictDeps = true;
      setupHook = "${nixpkgs}/pkgs/development/compilers/zig/setup-hook.sh";
      env = {
        # This zig_default_optimize_flag below is meant to avoid CPU feature impurity in
        # Nixpkgs. However, this flagset is "unstable": it is specifically meant to
        # be controlled by the upstream development team - being up to that team
        # exposing or not that flags to the outside (especially the package manager
        # teams).

        # Because of this hurdle, @andrewrk from Zig Software Foundation proposed
        # some solutions for this issue. Hopefully they will be implemented in
        # future releases of Zig. When this happens, this flagset should be
        # revisited accordingly.

        # Below are some useful links describing the discovery process of this 'bug'
        # in Nixpkgs:

        # https://github.com/NixOS/nixpkgs/issues/169461
        # https://github.com/NixOS/nixpkgs/issues/185644
        # https://github.com/NixOS/nixpkgs/pull/197046
        # https://github.com/NixOS/nixpkgs/pull/241741#issuecomment-1624227485
        # https://github.com/ziglang/zig/issues/14281#issuecomment-1624220653
        zig_default_cpu_flag = "-Dcpu=baseline";

        zig_default_optimize_flag =
          if lib.versionAtLeast finalAttrs.version "0.12" then
            "--release=safe"
          else if lib.versionAtLeast finalAttrs.version "0.11" then
            "-Doptimize=ReleaseSafe"
          else
            "-Drelease-safe=true";
      };
      installPhase = ''
        mkdir -p $out/{doc,bin,lib}
        [ -d docs ] && cp -r docs/* $out/doc
        [ -d doc ] && cp -r doc/* $out/doc
        cp -r lib/* $out/lib
        substituteInPlace $out/lib/std/zig/system.zig \
          --replace "/usr/bin/env" "${pkgs.lib.getExe' pkgs.coreutils "env"}"
        cp zig $out/bin/zig
      '';

      passthru = let
        mkPassthru = import "${nixpkgs}/pkgs/development/compilers/zig/passthru.nix";
      in
        mkPassthru ({
            inherit
              (pkgs)
              stdenv
              callPackage
              wrapCCWith
              wrapBintoolsWith
              overrideCC
              ;
            zig = finalAttrs.finalPackage;
          }
          // lib.optionalAttrs ((builtins.functionArgs mkPassthru) ? lib) {
            inherit lib;
          }
          // lib.optionalAttrs ((builtins.functionArgs mkPassthru) ? targetPackages) {
            inherit (pkgs) targetPackages;
          });

      meta =
        pkgs.zig.meta
        // {
          inherit platforms;
        };
    });

  # The packages that are tagged releases
  taggedPackages =
    lib.attrsets.mapAttrs
    (k: v:
      mkBinaryInstall {
        inherit (v.${system}) version url sha256;
        platforms = builtins.attrNames v;
      })
    (lib.attrsets.filterAttrs
      (k: v: (builtins.hasAttr system v) && (v.${system}.url != null) && (v.${system}.sha256 != null))
      (builtins.removeAttrs sources ["master"]));

  # The master packages
  masterPackages =
    lib.attrsets.mapAttrs' (
      k: v:
        lib.attrsets.nameValuePair
        (
          if k == "latest"
          then "master"
          else ("master-" + k)
        )
        (mkBinaryInstall {
          inherit (v.${system}) version url sha256;
          platforms = builtins.attrNames v;
        })
    )
    (lib.attrsets.filterAttrs
      (k: v: (builtins.hasAttr system v) && (v.${system}.url != null))
      sources.master);

  # This determines the latest /released/ version.
  latest = lib.lists.last (
    builtins.sort
    (x: y: (builtins.compareVersions x y) < 0)
    (builtins.attrNames taggedPackages)
  );
in
  # We want the packages but also add a "default" that just points to the
  # latest released version.
  taggedPackages // masterPackages // {"default" = taggedPackages.${latest}; inherit mkBinaryInstall;}
