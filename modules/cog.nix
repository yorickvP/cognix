{ config, lib, dream2nix, pkgs, ... }:
let
  cfg = config.cog.build;

  # conditional overrides: only active when a lib is in use
  pipOverridesModule = { config, lib, ... }:
    let
      overrides = import ./../overrides.nix;
      metadata = config.lock.content.fetchPipMetadata.sources;
    in {
      pip.drvs = lib.mapAttrs (name: info: overrides.${name} or { }) metadata;
    };

  # derivation containing all files in dir, basis of /src
  entirePackage = pkgs.runCommand "cog-source" {
    src = "${config.paths.projectRoot}/${config.paths.package}";
    nativeBuildInputs = [ pkgs.yj pkgs.jq ];
  } ''
    mkdir $out
    cp -r $src $out/src
    chmod -R +w $out
    # we have to modify cog.yaml to make sure predict: is in there
    yj < $src/cog.yaml | jq --arg PREDICT "${config.cog.predict}" '.predict = $PREDICT' > $out/src/cog.yaml
  '';
  # add org.cogmodel and run.cog prefixes to attr set
  mapAttrNames = f: set:
    lib.listToAttrs (map (attr: { name = f attr; value = set.${attr}; }) (lib.attrNames set));
  addLabelPrefix = labels: (mapAttrNames (x: "run.cog.${x}") labels) // (mapAttrNames (x: "org.cogmodel.${x}") labels);
  # hack: replicate calls "pip -U cog" before starting
  fakePip = pkgs.writeShellScriptBin "pip" ''
    echo "$@"
  '';
  # resolve system_packages to cognix.systemPackages
  resolvedSystemPackages = map (pkg:
    if lib.isDerivation pkg then pkg else
      config.cognix.systemPackages.${pkg}) cfg.system_packages;

  proxyLockModule = content: {
    # we put python env deps in config.python-env
    # but lock should be top-level
    disabledModules = [ dream2nix.modules.dream2nix.lock ];
    options.lock = {
      fields = lib.mkOption {};
      invalidationData = lib.mkOption {};
      content = lib.mkOption {
        default = content;
      };
    };
  };
in {
  imports = [
    ./cog-interface.nix
    ./stream-layered-image.nix
    ({ config, ... }: { public.config = config; })
  ];
  options.openapi-spec = with lib; mkOption {
    type = types.path;
  };
  config = {
    dockerTools.streamLayeredImage = {
      passthru.entirePackage = entirePackage;
      # glibc.out is needed for gpu
      contents = with pkgs;
        [
          bashInteractive
          busybox
          config.python-env.public.pyEnv
          entirePackage
          fakePip
          glibc.out
        ] ++ resolvedSystemPackages;
      config = {
        Entrypoint = [ "${pkgs.tini}/bin/tini" "--" ];
        EXPOSE = 5000;
        CMD = [ "python" "-m" "cog.server.http" ];
        WorkingDir = "/src";
        # todo: my cog doesn't like run.cog.config
        # todo: extract openapi schema in nix build (optional?)
        Labels = addLabelPrefix {
          has_init = "true";
          config = builtins.toJSON { build.gpu = cfg.gpu; };
          openapi_schema = builtins.readFile config.openapi-spec;
          cog_version = "0.8.6";
        };
      };
      # needed for gpu:
      # fixed in https://github.com/NixOS/nixpkgs/pull/260063
      extraCommands = "mkdir tmp";
    };
    lock = {
      inherit (config.python-env.public.config.lock) fields invalidationData;
    };
    openapi-spec = lib.mkDefault (pkgs.runCommandNoCC "openapi.json" {} ''
      cd ${entirePackage}/src
      ${config.python-env.public.pyEnv}/bin/python -m cog.command.openapi_schema > $out
    '');
    python-env = {
      imports = [
        dream2nix.modules.dream2nix.pip
        pipOverridesModule
        (proxyLockModule config.lock.content)
      ];
      paths = { inherit (config.paths) projectRoot package; };
      name = "cog-docker-env";
      version = "0.1.0";
      deps.python = {
        "3.8" = pkgs.python38;
        "3.9" = pkgs.python39;
        "3.10" = pkgs.python310;
        "3.11" = pkgs.python311;
        "3.12" = pkgs.python312;
      }.${cfg.python_version};
      pip = {
        pypiSnapshotDate = cfg.python_snapshot_date;
        requirementsList = [ "cog==0.8.6" ] ++ cfg.python_packages;
        #requirementsList = [ "${./inputs}/cog-0.0.1.dev-py3-none-any.whl" ];
        flattenDependencies = true; # todo: why?
        drvs = { };
      };
    };
  };
}
