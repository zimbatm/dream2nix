# like ./default.nix but system intependent
# (allows to generate outputs for several systems)
# follows flake output schema

{
  dlib,
  nixpkgsSrc,
  lib,
  overridesDirs,
  externalSources,
  externalPaths,

}@args:

let

  b = builtins;

  l = lib // builtins;

  dream2nixForSystem = config: system: pkgs:
    import ./default.nix
      { inherit config externalPaths externalSources pkgs; };


  # TODO: design output schema for cross compiled packages
  makePkgsKey = pkgs:
    let
      build = pkgs.buildPlatform.system;
      host = pkgs.hostPlatform.system;
    in
      if build == host then build
      else throw "cross compiling currently not supported";

  makeNixpkgs = pkgsList: systems:

    # fail if neither pkgs nor systems are defined
    if pkgsList == null && systems == [] then
      throw "Either `systems` or `pkgs` must be defined"

    # fail if pkgs and systems are both defined
    else if pkgsList != null && systems != [] then
      throw "Define either `systems` or `pkgs`, not both"

    # only pkgs is specified
    else if pkgsList != null then
      if b.isList pkgsList then
        lib.listToAttrs
          (pkgs: lib.nameValuePair (makePkgsKey pkgs) pkgs)
          pkgsList
      else
        { "${makePkgsKey pkgsList}" = pkgsList; }

    # only systems is specified
    else
      lib.genAttrs systems
        (system: import nixpkgsSrc { inherit system; });


    flakifyBuilderOutputs = system: outputs:
      l.mapAttrs
        (ouputType: outputValue: { "${system}" = outputValue; })
        outputs;

  init =
    {
      pkgs ? null,
      systems ? [],
      config ? {},
    }@argsInit:
    let

      config' = (import ./utils/config.nix).loadConfig argsInit.config or {};

      config = config' // {
        overridesDirs = args.overridesDirs ++ config'.overridesDirs;
      };

      allPkgs = makeNixpkgs pkgs systems;

      forAllSystems = f: lib.mapAttrs f allPkgs;

      dream2nixFor = forAllSystems (dream2nixForSystem config);
    in
      {

        riseAndShine = throw "Use makeFlakeOutputs instead of riseAndShine.";

        makeFlakeOutputs = mArgs: makeFlakeOutputsFunc
          (
            { inherit config pkgs systems; }
            // mArgs
          );

        apps =
          forAllSystems
            (system: pkgs:
              dream2nixFor."${system}".apps.flakeApps);

        defaultApp =
          forAllSystems
            (system: pkgs:
              dream2nixFor."${system}".apps.flakeApps.dream2nix);

      };

  makeFlakeOutputsFunc =
    {
      pname ? throw "Please pass `pname` to makeFlakeOutputs",
      pkgs ? null,
      settings ? [],
      source,
      systems ? [],
      translator ? null,
      translatorArgs ? {},
      ...
    }@args:
    let

      config = args.config or ((import ./utils/config.nix).loadConfig {});
      argsForward = b.removeAttrs args [ "config" "pname" "pkgs" "systems" ];
      allPkgs = makeNixpkgs pkgs systems;
      forAllSystems = f: b.mapAttrs f allPkgs;
      dream2nixFor = forAllSystems (dream2nixForSystem config);
      discoveredProjects = dlib.discoverers.discoverProjects {
        inherit settings;
        tree = dlib.prepareSourceTree { inherit source; };
      };

      allBuilderOutputs =
        lib.mapAttrs
          (system: pkgs:
            let
              dream2nix = dream2nixFor."${system}";

              dreamLocks = dream2nix.resolveProjectsFromSource {
                inherit pname settings source;
              };
            in
              dream2nix.realizeProjects {
                inherit dreamLocks source;
              })
          allPkgs;

      flakifiedOutputsList =
        lib.mapAttrsToList
          (system: outputs: flakifyBuilderOutputs system outputs)
          allBuilderOutputs;

      flakeOutputsBuilders =
        b.foldl'
          (allOutputs: output: lib.recursiveUpdate allOutputs output)
          {}
          flakifiedOutputsList;

      flakeOutputs =
        { projectsJson = l.toJSON (discoveredProjects); }
        // flakeOutputsBuilders;

    in
      lib.recursiveUpdate
        flakeOutputs
        {
          apps = forAllSystems (system: pkgs: {
            resolve.type = "app";
            resolve.program =
              let
                utils = (dream2nixFor."${system}".utils);

                # TODO: Too many calls to findOneTranslator.
                #   -> make findOneTranslator system independent
                translatorFound =
                  dream2nixFor."${system}".translators.findOneTranslator {
                    inherit source;
                    translatorName = args.translator or null;
                  };
              in
                b.toString
                  (utils.makePackageLockScript {
                    inherit source translatorArgs;
                    packagesDir = config.packagesDir;
                    translator = translatorFound.name;
                  });
          });
        };

in
{
  inherit dlib init;
  riseAndShine = throw "Use makeFlakeOutputs instead of riseAndShine.";
  makeFlakeOutpus = makeFlakeOutputsFunc;
}
