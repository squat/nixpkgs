{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    optionalAttrs
    optionalString
    types
    ;

  cfg = config.services.linkding;
in
{
  options.services.linkding = {
    enable = mkEnableOption "linkding, a self-hosted bookmark manager";

    package = mkPackageOption pkgs "linkding" { };

    user = mkOption {
      type = types.str;
      default = "linkding";
      description = ''
        User account under which linkding runs.

        ::: {.note}
        If left as the default value this user will automatically be created
        on system activation, otherwise you are responsible for ensuring the
        user exists before the linkding service starts.
        :::
      '';
    };

    group = mkOption {
      type = types.str;
      default = "linkding";
      description = ''
        Group under which linkding runs.

        ::: {.note}
        If left as the default value this group will automatically be created
        on system activation, otherwise you are responsible for ensuring the
        group exists before the linkding service starts.
        :::
      '';
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/linkding";
      description = "Directory used for all mutable state: SQLite database, secret key, favicons, previews, and assets.";
    };

    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address on which linkding listens.";
    };

    port = mkOption {
      type = types.port;
      default = 9090;
      description = "Port on which linkding listens.";
    };

    contextPath = mkOption {
      type = types.str;
      default = "";
      example = "linkding/";
      description = ''
        Configures a URL context path under which linkding is accessible.
        When set, linkding is available at `http://host:<port>/<contextPath>`.
        Must end with a `/` when non-empty.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/linkding.env";
      description = ''
        Path to an environment file loaded by all linkding services.
        Useful for injecting secrets that should not appear in the Nix store,
        such as `LD_DB_PASSWORD` or `LD_SUPERUSER_PASSWORD`.
      '';
    };

    settings = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        LD_DISABLE_BACKGROUND_TASKS = "True";
        LD_DISABLE_URL_VALIDATION = "True";
        LD_ENABLE_OIDC = "True";
      };
      description = ''
        Additional environment variables passed to linkding.
        Refer to the [linkding documentation](https://github.com/sissbruecker/linkding/blob/master/docs/Options.md)
        for the full list of supported `LD_*` options.
      '';
    };

    database = {
      type = mkOption {
        type = types.enum [
          "sqlite"
          "postgres"
        ];
        default = "sqlite";
        description = "Database engine to use. Defaults to SQLite.";
      };

      host = mkOption {
        type = types.str;
        default = "localhost";
        description = "PostgreSQL server host.";
      };

      port = mkOption {
        type = types.port;
        default = 5432;
        description = "PostgreSQL server port.";
      };

      name = mkOption {
        type = types.str;
        default = "linkding";
        description = "PostgreSQL database name.";
      };

      user = mkOption {
        type = types.str;
        default = "linkding";
        description = "PostgreSQL user name.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/secrets/linkding-db-password";
        description = "File containing the PostgreSQL password. When set, its contents are exported as `LD_DB_PASSWORD` at service start.";
      };

      createLocally = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to automatically create a local PostgreSQL database and user.";
      };
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the linkding port in the firewall.";
    };
  };

  config = mkIf cfg.enable (
    let
      pkg = cfg.package;

      usePostgres = cfg.database.type == "postgres";

      # Build the environment passed to every linkding process.
      environment = {
        DJANGO_SETTINGS_MODULE = "bookmarks.settings.prod";
        _NIXOS_LINKDING_DATA_DIR = cfg.dataDir;
        LD_SERVER_PORT = toString cfg.port;
      }
      // optionalAttrs (cfg.contextPath != "") {
        LD_CONTEXT_PATH = cfg.contextPath;
      }
      // optionalAttrs usePostgres {
        LD_DB_ENGINE = "postgres";
        LD_DB_HOST = if cfg.database.createLocally then "" else cfg.database.host;
        LD_DB_PORT = toString cfg.database.port;
        LD_DB_DATABASE = cfg.database.name;
        LD_DB_USER = cfg.database.user;
      }
      // cfg.settings;

      environmentFile = pkgs.writeText "linkding-environment" (lib.generators.toKeyValue { } environment);

      # Generate a uwsgi.ini for the linkding instance, adapted for NixOS from
      # the upstream uwsgi.ini. The static-map entries serve pre-generated
      # static files from the Nix store as well as the mutable user-data
      # directories (favicons, previews) from the data directory.
      uwsgiIni = pkgs.writeText "linkding-uwsgi.ini" ''
        [uwsgi]
        plugins-dir = ${pkg.passthru.uwsgiWithPython}/lib/uwsgi
        plugin = python3
        module = bookmarks.wsgi:application
        env = DJANGO_SETTINGS_MODULE=bookmarks.settings.prod
        processes = 2
        threads = 2
        buffer-size = 8192
        die-on-term = true
        mime-file = ${pkgs.mailcap}/etc/mime.types
        http = ${cfg.address}:${toString cfg.port}
        static-map = /${cfg.contextPath}static=${pkg}/${pkg.passthru.python.sitePackages}/bookmarks/static
        static-map = /${cfg.contextPath}static=${cfg.dataDir}/favicons
        static-map = /${cfg.contextPath}static=${cfg.dataDir}/previews
        static-map = /${cfg.contextPath}robots.txt=${pkg}/${pkg.passthru.python.sitePackages}/bookmarks/static/robots.txt

        if-env = LD_REQUEST_TIMEOUT
        http-timeout = %(_)
        socket-timeout = %(_)
        harakiri = %(_)
        endif =

        if-env = LD_REQUEST_MAX_CONTENT_LENGTH
        limit-post = %(_)
        endif =

        if-env = LD_LOG_X_FORWARDED_FOR
        log-x-forwarded-for = %(_)
        endif =

        if-env = LD_DISABLE_REQUEST_LOGS=true
        disable-logging = true
        log-4xx = true
        log-5xx = true
        endif =
      '';

      # Shell snippet that loads credentials from files at service start so
      # that secrets never appear in the Nix store.
      loadSecrets = optionalString (usePostgres && cfg.database.passwordFile != null) ''
        export LD_DB_PASSWORD="$(<${cfg.database.passwordFile})"
      '';

      # Manage wrapper script installed into the system PATH so administrators can
      # run Django management commands as the linkding service user.
      linkdingManageScript = pkgs.writeShellScriptBin "linkding-manage" ''
        set -eou pipefail
        set -a
        source ${environmentFile}
        ${optionalString (cfg.environmentFile != null) "source ${cfg.environmentFile}"}
        set +a
        ${loadSecrets}
        sudo=exec
        if [[ "$USER" != "${cfg.user}" ]]; then
          sudo="${config.security.wrapperDir}/sudo -E -u ${cfg.user}"
        fi
        $sudo ${lib.getExe' pkg "linkding"} "$@"
      '';

      commonServiceConfig = {
        User = cfg.user;
        Group = cfg.group;
        EnvironmentFile = [
          environmentFile
        ]
        ++ lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        Environment = lib.optional usePostgres "PYTHONPATH=${pkg.passthru.python.pkgs.makePythonPath pkg.optional-dependencies.postgres}";
        WorkingDirectory = cfg.dataDir;
        StateDirectory = [
          "linkding"
          "linkding/favicons"
          "linkding/previews"
          "linkding/assets"
        ];
        StateDirectoryMode = "0750";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
      };
    in
    {
      assertions = [
        {
          assertion = cfg.database.createLocally -> usePostgres;
          message = "services.linkding.database.createLocally requires services.linkding.database.type = \"postgres\"";
        }
        {
          assertion =
            cfg.database.createLocally -> cfg.database.host == "localhost" || cfg.database.host == "";
          message = "services.linkding.database.host should be empty or \"localhost\" when createLocally is enabled";
        }
        {
          assertion = cfg.database.createLocally -> cfg.database.passwordFile == null;
          message = "services.linkding.database.passwordFile must not be set when createLocally is enabled";
        }
        {
          assertion =
            cfg.database.createLocally
            -> cfg.database.user == cfg.user && cfg.database.user == cfg.database.name;
          message = "services.linkding.database.user must match services.linkding.user and services.linkding.database.name when createLocally is enabled";
        }
        {
          assertion = cfg.contextPath == "" || lib.hasSuffix "/" cfg.contextPath;
          message = "services.linkding.contextPath must end with \"/\" when non-empty";
        }
      ];

      networking.firewall = mkIf cfg.openFirewall {
        allowedTCPPorts = [ cfg.port ];
      };

      environment.systemPackages = [ linkdingManageScript ];

      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
      };

      users.groups.${cfg.group} = { };

      # One-shot setup service: run database migrations and first-time
      # initialization steps taken from the upstream bootstrap.sh.
      systemd.services.linkding-setup = {
        description = "linkding database migrations and initialization";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
        ]
        ++ lib.optionals (usePostgres && cfg.database.createLocally) [ "postgresql.target" ];
        requires = lib.optionals (usePostgres && cfg.database.createLocally) [ "postgresql.target" ];

        serviceConfig = commonServiceConfig // {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          ${loadSecrets}

          ${optionalString (usePostgres && cfg.database.createLocally) ''
            count=0
            timeout=30
            until ${pkgs.postgresql}/bin/pg_isready -h ${cfg.database.host} -p ${toString cfg.database.port}; do
              if [ $count -ge $timeout ]; then
                echo "Timed out waiting for PostgreSQL after $timeout seconds."
                exit 1
              fi
              echo "Waiting for PostgreSQL... ($count/$timeout)"
              sleep 1
              count=$((count+1))
            done
          ''}

          ${lib.getExe' pkg "linkding-bootstrap"}
        '';
      };

      # Main WSGI service — starts after setup completes.
      systemd.services.linkding = {
        description = "linkding bookmark manager";
        wantedBy = [ "multi-user.target" ];
        after = [ "linkding-setup.service" ];
        requires = [ "linkding-setup.service" ];

        serviceConfig = commonServiceConfig // {
          Type = "exec";
          ExecStart = "${lib.getExe' pkg "uwsgi"} --ini ${uwsgiIni}";
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };

      # Background task processor (Huey). Can be disabled via
      # services.linkding.settings.LD_DISABLE_BACKGROUND_TASKS = "True".
      systemd.services.linkding-background-tasks =
        mkIf ((cfg.settings.LD_DISABLE_BACKGROUND_TASKS or "False") != "True")
          {
            description = "linkding background task processor";
            wantedBy = [ "multi-user.target" ];
            after = [ "linkding-setup.service" ];
            requires = [ "linkding-setup.service" ];

            serviceConfig = commonServiceConfig // {
              Type = "exec";
              ExecStart = "${lib.getExe' pkg "linkding"} run_huey -f";
              Restart = "on-failure";
              RestartSec = "5s";
            };
          };

      # Automatically provision a local PostgreSQL database when requested.
      services.postgresql = mkIf cfg.database.createLocally {
        enable = true;
        ensureDatabases = [ cfg.database.name ];
        ensureUsers = [
          {
            name = cfg.database.user;
            ensureDBOwnership = true;
          }
        ];
      };
    }
  );

  meta.maintainers = with lib.maintainers; [ squat ];
}
