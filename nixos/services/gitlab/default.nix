{ config, lib, pkgs, utils, ... }:

with lib;

let
  cfg = config.services.gitlab;

  ruby = cfg.packages.gitlab.ruby;

  postgresqlPackage =
    if config.services.postgresql.enable
    then config.services.postgresql.package
    else pkgs.postgresql;

  gitlabSocket = "${cfg.statePath}/tmp/sockets/gitlab.socket";
  gitalySocket = "${cfg.statePath}/tmp/sockets/gitaly.socket";
  pathUrlQuote = url: replaceStrings ["/"] ["%2F"] url;

  databaseConfig = {
    production = {
      adapter = "postgresql";
      database = cfg.databaseName;
      host = cfg.databaseHost;
      username = cfg.databaseUsername;
      encoding = "utf8";
      pool = cfg.databasePool;
    } // cfg.extraDatabaseConfig;
  };

  # We only want to create a database if we're actually going to connect to it.
  databaseActuallyCreateLocally = cfg.databaseCreateLocally && cfg.databaseHost == "";

  gitalyToml = pkgs.writeText "gitaly.toml" ''
    socket_path = "${lib.escape ["\""] gitalySocket}"
    bin_dir = "${cfg.packages.gitaly}/bin"
    prometheus_listen_addr = "localhost:9236"

    [git]
    bin_path = "${pkgs.git}/bin/git"

    [gitaly-ruby]
    dir = "${cfg.packages.gitaly.ruby}"

    [gitlab-shell]
    dir = "${cfg.packages.gitlab-shell}"

    [gitlab]
    secret_file = "${cfg.statePath}/gitlab_shell_secret"
    url = "http+unix://${pathUrlQuote gitlabSocket}"

    [gitlab.http-settings]
    self_signed_cert = false

    ${concatStringsSep "\n" (attrValues (mapAttrs (k: v: ''
    [[storage]]
    name = "${lib.escape ["\""] k}"
    path = "${lib.escape ["\""] v.path}"
    '') gitlabConfig.production.repositories.storages))}
  '';

  gitlabShellConfig = flip recursiveUpdate cfg.extraShellConfig {
    user = cfg.user;
    gitlab_url = "http+unix://${pathUrlQuote gitlabSocket}";
    http_settings.self_signed_cert = false;
    repos_path = "${cfg.statePath}/repositories";
    secret_file = "${cfg.statePath}/gitlab_shell_secret";
    log_file = "/var/log/gitlab/gitlab-shell.log";
    custom_hooks_dir = "${cfg.statePath}/custom_hooks";
    redis = {
      bin = "${pkgs.redis}/bin/redis-cli";
      host = "127.0.0.1";
      port = 6379;
      database = 0;
      password = cfg.redisPassword;
      namespace = "resque:gitlab";
    };
  };

  redisConfig.production.url = "redis://:${cfg.redisPassword}@localhost:6379/";

  gitlabConfig = {
    # These are the default settings from config/gitlab.example.yml
    production = flip recursiveUpdate cfg.extraConfig {
      gitlab = {
        host = cfg.host;
        port = cfg.port;
        https = cfg.https;
        user = cfg.user;
        email_enabled = true;
        email_display_name = "GitLab";
        email_reply_to = "noreply@localhost";
        default_theme = 2;
        default_projects_features = {
          issues = true;
          merge_requests = true;
          wiki = true;
          snippets = true;
          builds = true;
          container_registry = cfg.registry.defaultForProjects;
        };
      };
      repositories.storages.default.path = "${cfg.statePath}/repositories";
      repositories.storages.default.gitaly_address = "unix:${gitalySocket}";
      artifacts.enabled = true;
      lfs.enabled = true;
      gravatar.enabled = true;
      cron_jobs = { };
      gitlab_ci.builds_path = "${cfg.statePath}/builds";
      ldap.enabled = false;
      omniauth.enabled = false;
      shared.path = "${cfg.statePath}/shared";
      gitaly.client_path = "${cfg.packages.gitaly}/bin";
      backup.path = "${cfg.backupPath}";
      gitlab_shell = {
        path = "${cfg.packages.gitlab-shell}";
        hooks_path = "${cfg.statePath}/shell/hooks";
        secret_file = "${cfg.statePath}/gitlab_shell_secret";
        upload_pack = true;
        receive_pack = true;
      };
      workhorse.secret_file = "${cfg.statePath}/.gitlab_workhorse_secret";
      gitlab_kas.secret_file = "${cfg.statePath}/.gitlab_kas_secret";
      git.bin_path = "git";
      monitoring = {
        ip_whitelist = [ "127.0.0.0/8" "::1/128" ];
        sidekiq_exporter = {
          enable = true;
          address = "localhost";
          port = 3807;
        };
      };
      registry = lib.optionalAttrs cfg.registry.enable {
        enabled = true;
        host = cfg.registry.externalAddress;
        port = cfg.registry.externalPort;
        key = cfg.registry.keyFile;
        api_url = "http://${config.services.dockerRegistry.listenAddress}:${toString config.services.dockerRegistry.port}/";
        issuer = "gitlab-issuer";
      };
      extra = {};
      uploads.storage_path = cfg.statePath;
      incoming_email = {
        enabled = cfg.incomingEmail.enable;
        address = cfg.incomingEmail.address;
        user = cfg.incomingEmail.user;
        host = cfg.incomingEmail.host;
        port = cfg.incomingEmail.port;
        ssl = cfg.incomingEmail.ssl;
        start_tls = cfg.incomingEmail.startTLS;
        mailbox = cfg.incomingEmail.mailbox;
        idle_timeout = cfg.incomingEmail.idleTimeout;
        expunge_deleted = cfg.incomingEmail.expungeDeleted;
        log_path = cfg.incomingEmail.logPath;
      } //
      (optionalAttrs (cfg.incomingEmail.passwordFile != null) {
        password = fileContents cfg.incomingEmail.passwordFile;
      });
    };
  };

  gitlabEnv = {
    HOME = "${cfg.statePath}/home";
    UNICORN_PATH = "${cfg.statePath}/";
    GITLAB_PATH = "${cfg.packages.gitlab}/share/gitlab/";
    SCHEMA = "${cfg.statePath}/db/structure.sql";
    GITLAB_UPLOADS_PATH = "${cfg.statePath}/uploads";
    GITLAB_LOG_PATH = "/var/log/gitlab";
    GITLAB_REDIS_CONFIG_FILE = pkgs.writeText "redis.yml" (builtins.toJSON redisConfig);
    prometheus_multiproc_dir = "/run/gitlab";
    RAILS_ENV = "production";
  };

  gitlab-rake = pkgs.stdenv.mkDerivation {
    name = "gitlab-rake";
    buildInputs = [ pkgs.makeWrapper ];
    dontBuild = true;
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      makeWrapper ${cfg.packages.gitlab.rubyEnv}/bin/rake $out/bin/gitlab-rake \
          ${concatStrings (mapAttrsToList (name: value: "--set ${name} '${value}' ") gitlabEnv)} \
          --set PATH '${lib.makeBinPath [ pkgs.nodejs pkgs.gzip pkgs.git pkgs.gnutar postgresqlPackage pkgs.coreutils pkgs.procps ]}:$PATH' \
          --set RAKEOPT '-f ${cfg.packages.gitlab}/share/gitlab/Rakefile' \
          --run 'cd ${cfg.packages.gitlab}/share/gitlab'
     '';
  };

  gitlab-rails = pkgs.stdenv.mkDerivation {
    name = "gitlab-rails";
    buildInputs = [ pkgs.makeWrapper ];
    dontBuild = true;
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      makeWrapper ${cfg.packages.gitlab.rubyEnv}/bin/rails $out/bin/gitlab-rails \
          ${concatStrings (mapAttrsToList (name: value: "--set ${name} '${value}' ") gitlabEnv)} \
          --set PATH '${lib.makeBinPath [ pkgs.nodejs pkgs.gzip pkgs.git pkgs.gnutar postgresqlPackage pkgs.coreutils pkgs.procps ]}:$PATH' \
          --run 'cd ${cfg.packages.gitlab}/share/gitlab'
     '';
  };

  extraGitlabRb = pkgs.writeText "extra-gitlab.rb" cfg.extraGitlabRb;

  smtpSettings = pkgs.writeText "gitlab-smtp-settings.rb" ''
    if Rails.env.production?
      Rails.application.config.action_mailer.delivery_method = :smtp

      ActionMailer::Base.delivery_method = :smtp
      ActionMailer::Base.smtp_settings = {
        address: "${cfg.smtp.address}",
        port: ${toString cfg.smtp.port},
        ${optionalString (cfg.smtp.username != null) ''user_name: "${cfg.smtp.username}",''}
        ${optionalString (cfg.smtp.passwordFile != null) ''password: "@smtpPassword@",''}
        domain: "${cfg.smtp.domain}",
        ${optionalString (cfg.smtp.authentication != null) "authentication: :${cfg.smtp.authentication},"}
        enable_starttls_auto: ${boolToString cfg.smtp.enableStartTLSAuto},
        ca_file: "/etc/ssl/certs/ca-certificates.crt",
        openssl_verify_mode: '${cfg.smtp.opensslVerifyMode}'
      }
    end
  '';

in {

  imports = [
    (mkRenamedOptionModule [ "services" "gitlab" "stateDir" ] [ "services" "gitlab" "statePath" ])
    (mkRemovedOptionModule [ "services" "gitlab" "satelliteDir" ] "")
  ];

  options = {
    services.gitlab = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable the gitlab service.
        '';
      };

      packages.gitlab = mkOption {
        type = types.package;
        default = pkgs.gitlab;
        defaultText = "pkgs.gitlab";
        description = "Reference to the gitlab package";
        example = "pkgs.gitlab-ee";
      };

      packages.gitlab-shell = mkOption {
        type = types.package;
        default = pkgs.gitlab-shell;
        defaultText = "pkgs.gitlab-shell";
        description = "Reference to the gitlab-shell package";
      };

      packages.gitlab-workhorse = mkOption {
        type = types.package;
        default = pkgs.gitlab-workhorse;
        defaultText = "pkgs.gitlab-workhorse";
        description = "Reference to the gitlab-workhorse package";
      };

      packages.gitaly = mkOption {
        type = types.package;
        default = pkgs.gitaly;
        defaultText = "pkgs.gitaly";
        description = "Reference to the gitaly package";
      };

      statePath = mkOption {
        type = types.str;
        default = "/var/gitlab/state";
        description = ''
          Gitlab state directory. Configuration, repositories and
          logs, among other things, are stored here.

          The directory will be created automatically if it doesn't
          exist already. Its parent directories must be owned by
          either <literal>root</literal> or the user set in
          <option>services.gitlab.user</option>.
        '';
      };

      backupPath = mkOption {
        type = types.str;
        default = cfg.statePath + "/backup";
        description = "Gitlab path for backups.";
      };

      databaseHost = mkOption {
        type = types.str;
        default = "";
        description = ''
          Gitlab database hostname. An empty string means <quote>use
          local unix socket connection</quote>.
        '';
      };

      databasePasswordFile = mkOption {
        type = with types; nullOr path;
        default = null;
        description = ''
          File containing the Gitlab database user password.

          This should be a string, not a nix path, since nix paths are
          copied into the world-readable nix store.
        '';
      };

      databaseCreateLocally = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether a database should be automatically created on the
          local host. Set this to <literal>false</literal> if you plan
          on provisioning a local database yourself. This has no effect
          if <option>services.gitlab.databaseHost</option> is customized.
        '';
      };

      databaseName = mkOption {
        type = types.str;
        default = "gitlab";
        description = "Gitlab database name.";
      };

      databaseUsername = mkOption {
        type = types.str;
        default = "gitlab";
        description = "Gitlab database user.";
      };

      databasePool = mkOption {
        type = types.int;
        default = 5;
        description = "Database connection pool size.";
      };

      extraDatabaseConfig = mkOption {
        type = types.attrs;
        default = {};
        description = "Extra configuration in config/database.yml.";
      };

      extraGitlabRb = mkOption {
        type = types.str;
        default = "";
        example = ''
          if Rails.env.production?
            Rails.application.config.action_mailer.delivery_method = :sendmail
            ActionMailer::Base.delivery_method = :sendmail
            ActionMailer::Base.sendmail_settings = {
              location: "/run/wrappers/bin/sendmail",
              arguments: "-i -t"
            }
          end
        '';
        description = ''
          Extra configuration to be placed in config/extra-gitlab.rb. This can
          be used to add configuration not otherwise exposed through this module's
          options.
        '';
      };

      host = mkOption {
        type = types.str;
        default = config.networking.hostName;
        description = "Gitlab host name. Used e.g. for copy-paste URLs.";
      };

      port = mkOption {
        type = types.int;
        default = 8080;
        description = ''
          Gitlab server port for copy-paste URLs, e.g. 80 or 443 if you're
          service over https.
        '';
      };

      https = mkOption {
        type = types.bool;
        default = false;
        description = "Whether gitlab prints URLs with https as scheme.";
      };

      user = mkOption {
        type = types.str;
        default = "gitlab";
        description = "User to run gitlab and all related services.";
      };

      group = mkOption {
        type = types.str;
        default = "gitlab";
        description = "Group to run gitlab and all related services.";
      };

      initialRootEmail = mkOption {
        type = types.str;
        default = "admin@local.host";
        description = ''
          Initial email address of the root account if this is a new install.
        '';
      };

      initialRootPasswordFile = mkOption {
        type = with types; nullOr path;
        default = null;
        description = ''
          File containing the initial password of the root account if
          this is a new install.

          This should be a string, not a nix path, since nix paths are
          copied into the world-readable nix store.
        '';
      };

      redisPassword = mkOption {
        type = types.str;
      };

      registry = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable gitLab container registry.";
        };
        host = mkOption {
          type = types.str;
          default = config.services.gitlab.host;
          description = "GitLab container registry host name.";
        };
        port = mkOption {
          type = types.int;
          default = 4567;
          description = "GitLab container registry port.";
        };
        certFile = mkOption {
          type = types.path;
          default = null;
          description = "Path to gitLab container registry certificate.";
        };
        keyFile = mkOption {
          type = types.path;
          default = null;
          description = "Path to gitLab container registry certificate-key.";
        };
        defaultForProjects = mkOption {
          type = types.bool;
          default = cfg.registry.enable;
          description = "If gitlab container registry is project default.";
        };
        issuer = mkOption {
          type = types.str;
          default = "gitlab-issuer";
          description = "Gitlab container registry issuer.";
        };
        serviceName = mkOption {
          type = types.str;
          default = "container_registry";
          description = "Gitlab container registry service name.";
        };
        externalAddress = mkOption {
          type = types.str;
          default = "";
        };
        externalPort = mkOption {
          type = types.int;
        };
      };

      smtp = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable gitlab mail delivery over SMTP.";
        };

        address = mkOption {
          type = types.str;
          default = "localhost";
          description = "Address of the SMTP server for Gitlab.";
        };

        port = mkOption {
          type = types.int;
          default = 465;
          description = "Port of the SMTP server for Gitlab.";
        };

        username = mkOption {
          type = with types; nullOr str;
          default = null;
          description = "Username of the SMTP server for Gitlab.";
        };

        passwordFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            File containing the password of the SMTP server for Gitlab.

            This should be a string, not a nix path, since nix paths
            are copied into the world-readable nix store.
          '';
        };

        domain = mkOption {
          type = types.str;
          default = "localhost";
          description = "HELO domain to use for outgoing mail.";
        };

        authentication = mkOption {
          type = with types; nullOr str;
          default = null;
          description = "Authentitcation type to use, see http://api.rubyonrails.org/classes/ActionMailer/Base.html";
        };

        enableStartTLSAuto = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to try to use StartTLS.";
        };

        opensslVerifyMode = mkOption {
          type = types.str;
          default = "peer";
          description = "How OpenSSL checks the certificate, see http://api.rubyonrails.org/classes/ActionMailer/Base.html";
        };
      };

      incomingEmail = {
        enable = mkEnableOption "incoming mail processing via mail_room";

        host = mkOption {
          type = types.str;
          default = "localhost";
          description = "Address of the IMAP server";
        };

        port = mkOption {
          type = types.int;
          default = 143;
          description = "Port of the IMAP server";
        };

        user = mkOption {
          type = with types; nullOr str;
          default = null;
          description = "Login name for the IMAP account";
          example = "gitlab@example.org";
        };

        passwordFile = mkOption {
          type = with types; nullOr path;
          default = null;
          description = ''
            File containing the password of the IMAP account.

            This should be a string, not a Nix path, since nix paths
            are copied into the world-readable nix store.
          '';
        };

        address = mkOption {
          type = with types; nullOr str;
          default = null;
          description = ''
            E-mail address template for incoming mail processing. Must contain
            the placeholder "%{key}" somewhere.
          '';
          example = "gitlab-issue+%{key}@gitlab.example.com";
        };

        ssl = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to use IMAPs.";
        };

        startTLS = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to use STARTTLS over IMAP.";
        };

        mailbox = mkOption {
          type = types.string;
          default = "INBOX";
          description = "IMAP mailbox to search for incoming mails.";
        };

        idleTimeout = mkOption {
          type = types.int;
          default = 300;
          description = "IMAP IDLE interval.";
        };

        expungeDeleted = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to delete processed mails permantently.";
        };

        logPath = mkOption {
          type = types.path;
          default = "/var/log/gitlab/mail_room_json.log";
          description = "Log file location. Logs will be rotated automatically.";
        };
      };

      secrets.secretFile = mkOption {
        type = with types; nullOr path;
        default = null;
        description = ''
          A file containing the secret used to encrypt variables in
          the DB. If you change or lose this key you will be unable to
          access variables stored in database.

          Make sure the secret is at least 30 characters and all random,
          no regular words or you'll be exposed to dictionary attacks.

          This should be a string, not a nix path, since nix paths are
          copied into the world-readable nix store.
        '';
      };

      secrets.dbFile = mkOption {
        type = with types; nullOr path;
        default = null;
        description = ''
          A file containing the secret used to encrypt variables in
          the DB. If you change or lose this key you will be unable to
          access variables stored in database.

          Make sure the secret is at least 30 characters and all random,
          no regular words or you'll be exposed to dictionary attacks.

          This should be a string, not a nix path, since nix paths are
          copied into the world-readable nix store.
        '';
      };

      secrets.otpFile = mkOption {
        type = with types; nullOr path;
        default = null;
        description = ''
          A file containing the secret used to encrypt secrets for OTP
          tokens. If you change or lose this key, users which have 2FA
          enabled for login won't be able to login anymore.

          Make sure the secret is at least 30 characters and all random,
          no regular words or you'll be exposed to dictionary attacks.

          This should be a string, not a nix path, since nix paths are
          copied into the world-readable nix store.
        '';
      };

      secrets.jwsFile = mkOption {
        type = with types; nullOr path;
        default = null;
        description = ''
          A file containing the secret used to encrypt session
          keys. If you change or lose this key, users will be
          disconnected.

          Make sure the secret is an RSA private key in PEM format. You can
          generate one with

          openssl genrsa 2048

          This should be a string, not a nix path, since nix paths are
          copied into the world-readable nix store.
        '';
      };

      extraShellConfig = mkOption {
        type = types.attrs;
        default = {};
        description = "Extra configuration to merge into shell-config.yml";
      };

      extraConfig = mkOption {
        type = types.attrs;
        default = {};
        example = literalExample ''
          {
            gitlab = {
              default_projects_features = {
                builds = false;
              };
            };
            omniauth = {
              enabled = true;
              auto_sign_in_with_provider = "openid_connect";
              allow_single_sign_on = ["openid_connect"];
              block_auto_created_users = false;
              providers = [
                {
                  name = "openid_connect";
                  label = "OpenID Connect";
                  args = {
                    name = "openid_connect";
                    scope = ["openid" "profile"];
                    response_type = "code";
                    issuer = "https://keycloak.example.com/auth/realms/My%20Realm";
                    discovery = true;
                    client_auth_method = "query";
                    uid_field = "preferred_username";
                    client_options = {
                      identifier = "gitlab";
                      secret = { _secret = "/var/keys/gitlab_oidc_secret"; };
                      redirect_uri = "https://git.example.com/users/auth/openid_connect/callback";
                    };
                  };
                }
              ];
            };
          };
        '';
        description = ''
          Extra options to be added under
          <literal>production</literal> in
          <filename>config/gitlab.yml</filename>, as a nix attribute
          set.

          Options containing secret data should be set to an attribute
          set containing the attribute <literal>_secret</literal> - a
          string pointing to a file containing the value the option
          should be set to. See the example to get a better picture of
          this: in the resulting
          <filename>config/gitlab.yml</filename> file, the
          <literal>production.omniauth.providers[0].args.client_options.secret</literal>
          key will be set to the contents of the
          <filename>/var/keys/gitlab_oidc_secret</filename> file.
        '';
      };
    };
  };

  config = mkIf cfg.enable {

    assertions = [
      {
        assertion = databaseActuallyCreateLocally -> (cfg.user == cfg.databaseUsername);
        message = ''For local automatic database provisioning (services.gitlab.databaseCreateLocally == true) with peer authentication (services.gitlab.databaseHost == "") to work services.gitlab.user and services.gitlab.databaseUsername must be identical.'';
      }
      {
        assertion = (cfg.databaseHost != "") -> (cfg.databasePasswordFile != null);
        message = "When services.gitlab.databaseHost is customized, services.gitlab.databasePasswordFile must be set!";
      }
      {
        assertion = cfg.initialRootPasswordFile != null;
        message = "services.gitlab.initialRootPasswordFile must be set!";
      }
      {
        assertion = cfg.secrets.secretFile != null;
        message = "services.gitlab.secrets.secretFile must be set!";
      }
      {
        assertion = cfg.secrets.dbFile != null;
        message = "services.gitlab.secrets.dbFile must be set!";
      }
      {
        assertion = cfg.secrets.otpFile != null;
        message = "services.gitlab.secrets.otpFile must be set!";
      }
      {
        assertion = cfg.secrets.jwsFile != null;
        message = "services.gitlab.secrets.jwsFile must be set!";
      }
    ];

    environment.systemPackages = [ pkgs.git gitlab-rake gitlab-rails cfg.packages.gitlab-shell ];

    # Redis is required for the sidekiq queue runner.
    services.redis.enable = mkDefault true;

    # We use postgres as the main data store.
    services.postgresql = optionalAttrs databaseActuallyCreateLocally {
      enable = true;
      ensureUsers = singleton { name = cfg.databaseUsername; };
    };

    # The postgresql module doesn't currently support concepts like
    # objects owners and extensions; for now we tack on what's needed
    # here.
    systemd.services.gitlab-postgresql = let pgsql = config.services.postgresql; in mkIf databaseActuallyCreateLocally {
      after = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pgsql.package ];
      script = ''
        set -eu

        PSQL="${pkgs.utillinux}/bin/runuser -u ${pgsql.superUser} -- psql --port=${toString pgsql.port}"

        $PSQL -tAc "SELECT 1 FROM pg_database WHERE datname = '${cfg.databaseName}'" | grep -q 1 || $PSQL -tAc 'CREATE DATABASE "${cfg.databaseName}" OWNER "${cfg.databaseUsername}"'
        current_owner=$($PSQL -tAc "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_catalog.pg_database WHERE datname = '${cfg.databaseName}'")
        if [[ "$current_owner" != "${cfg.databaseUsername}" ]]; then
            $PSQL -tAc 'ALTER DATABASE "${cfg.databaseName}" OWNER TO "${cfg.databaseUsername}"'
            if [[ -e "${config.services.postgresql.dataDir}/.reassigning_${cfg.databaseName}" ]]; then
                echo "Reassigning ownership of database ${cfg.databaseName} to user ${cfg.databaseUsername} failed on last boot. Failing..."
                exit 1
            fi
            touch "${config.services.postgresql.dataDir}/.reassigning_${cfg.databaseName}"
            $PSQL "${cfg.databaseName}" -tAc "REASSIGN OWNED BY \"$current_owner\" TO \"${cfg.databaseUsername}\""
            rm "${config.services.postgresql.dataDir}/.reassigning_${cfg.databaseName}"
        fi
        $PSQL '${cfg.databaseName}' -tAc "CREATE EXTENSION IF NOT EXISTS pg_trgm"
        $PSQL '${cfg.databaseName}' -tAc "CREATE EXTENSION IF NOT EXISTS btree_gist;"
      '';

      serviceConfig = {
        Type = "oneshot";
      };
    };

    # Enable Docker Registry, if GitLab-Container Registry is enabled
    services.dockerRegistry = optionalAttrs cfg.registry.enable {
      enable = true;
      enableDelete = true; # This must be true, otherwise GitLab won't manage it correctly
      extraConfig = {
        auth.token = {
          realm = "http${if cfg.https == true then "s" else ""}://${cfg.host}/jwt/auth";
          service = cfg.registry.serviceName;
          issuer = cfg.registry.issuer;
          rootcertbundle = cfg.registry.certFile;
        };
      };
    };

    users.users.${cfg.user} =
      { group = cfg.group;
        home = "${cfg.statePath}/home";
        shell = "${pkgs.bash}/bin/bash";
        uid = config.ids.uids.gitlab;
      };

    users.groups.${cfg.group}.gid = config.ids.gids.gitlab;

    systemd.tmpfiles.rules = [
      "d /run/gitlab 0755 ${cfg.user} ${cfg.group} -"
      "d ${gitlabEnv.HOME} 0750 ${cfg.user} ${cfg.group} -"
      "z ${gitlabEnv.HOME}/.ssh/authorized_keys 0600 ${cfg.user} ${cfg.group} -"
      "d ${cfg.backupPath} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/builds 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/config 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/config/initializers 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/db 0750 ${cfg.user} ${cfg.group} -"
      "d /var/log/gitlab 0755 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/repositories 2770 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/shell 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/tmp 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/tmp/pids 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/tmp/sockets 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/uploads 0700 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/custom_hooks 0700 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/custom_hooks/pre-receive.d 0700 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/custom_hooks/post-receive.d 0700 ${cfg.user} ${cfg.group} -"
      "d ${cfg.statePath}/custom_hooks/update.d 0700 ${cfg.user} ${cfg.group} -"
      "d ${gitlabConfig.production.shared.path} 0750 ${cfg.user} ${cfg.group} -"
      "d ${gitlabConfig.production.shared.path}/artifacts 0750 ${cfg.user} ${cfg.group} -"
      "d ${gitlabConfig.production.shared.path}/lfs-objects 0750 ${cfg.user} ${cfg.group} -"
      "d ${gitlabConfig.production.shared.path}/pages 0750 ${cfg.user} ${cfg.group} -"
      "L+ /run/gitlab/config - - - - ${cfg.statePath}/config"
      "L+ /run/gitlab/log - - - - /var/log/gitlab"
      "L+ /run/gitlab/tmp - - - - ${cfg.statePath}/tmp"
      "L+ /run/gitlab/uploads - - - - ${cfg.statePath}/uploads"

      "L+ /run/gitlab/shell-config.yml - - - - ${pkgs.writeText "config.yml" (builtins.toJSON gitlabShellConfig)}"

      "L+ ${cfg.statePath}/config/unicorn.rb - - - - ${./defaultUnicornConfig.rb}"
    ];

    systemd.services.gitlab-sidekiq = {
      after = [ "network.target" "redis.service" "gitlab.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = gitlabEnv;
      path = with pkgs; [
        postgresqlPackage
        gitAndTools.git
        ruby
        openssh
        nodejs
        gnupg

        # Needed for GitLab project imports
        gnutar
        gzip
      ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        TimeoutSec = "infinity";
        Restart = "on-failure";
        WorkingDirectory = "${cfg.packages.gitlab}/share/gitlab";
        ExecStart="${cfg.packages.gitlab.rubyEnv}/bin/sidekiq -C \"${cfg.packages.gitlab}/share/gitlab/config/sidekiq_queues.yml\" -e production";
      };
    };

    systemd.services.gitaly = {
      after = [ "network.target" "gitlab.service" ];
      requires = [ "gitlab.service" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [
        openssh
        procps  # See https://gitlab.com/gitlab-org/gitaly/issues/1562
        gitAndTools.git
        cfg.packages.gitaly.rubyEnv
        cfg.packages.gitaly.rubyEnv.wrappedRuby
        gzip
        bzip2
      ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        TimeoutSec = "infinity";
        Restart = "on-failure";
        WorkingDirectory = gitlabEnv.HOME;
        ExecStart = "${cfg.packages.gitaly}/bin/gitaly ${gitalyToml}";
      };
    };

    systemd.services.gitlab-workhorse = {
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [
        exiftool
        gitAndTools.git
        gnutar
        gzip
        openssh
        gitlab-workhorse
      ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        TimeoutSec = "infinity";
        Restart = "on-failure";
        WorkingDirectory = gitlabEnv.HOME;
        ExecStart =
          "${cfg.packages.gitlab-workhorse}/bin/gitlab-workhorse "
          + "-listenUmask 0 "
          + "-listenNetwork unix "
          + "-listenAddr /run/gitlab/gitlab-workhorse.socket "
          + "-authSocket ${gitlabSocket} "
          + "-documentRoot ${cfg.packages.gitlab}/share/gitlab/public "
          + "-secretPath ${cfg.statePath}/.gitlab_workhorse_secret";
      };
    };

    systemd.services.gitlab = {
      after = [ "gitlab-workhorse.service" "network.target" "gitlab-postgresql.service" "redis.service" ];
      requires = [ "gitlab-sidekiq.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = gitlabEnv;
      path = with pkgs; [
        postgresqlPackage
        gitAndTools.git
        openssh
        nodejs
        procps
        gnupg
      ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        TimeoutSec = "infinity";
        Restart = "on-failure";
        WorkingDirectory = "${cfg.packages.gitlab}/share/gitlab";
        ExecStartPre = let
          preStartFullPrivileges = ''
            shopt -s dotglob nullglob
            set -eu

            chown --no-dereference '${cfg.user}':'${cfg.group}' '${cfg.statePath}'/*
            chown --no-dereference '${cfg.user}':'${cfg.group}' '${cfg.statePath}'/config/*
          '';
          preStart = ''
            set -eu

            cp -f ${cfg.packages.gitlab}/share/gitlab/VERSION ${cfg.statePath}/VERSION
            rm -rf ${cfg.statePath}/db/*
            rm -rf ${cfg.statePath}/config/initializers/*
            rm -f ${cfg.statePath}/lib
            cp -rf --no-preserve=mode ${cfg.packages.gitlab}/share/gitlab/config.dist/* ${cfg.statePath}/config
            cp -rf --no-preserve=mode ${cfg.packages.gitlab}/share/gitlab/db/* ${cfg.statePath}/db
            ln -sf ${extraGitlabRb} ${cfg.statePath}/config/initializers/extra-gitlab.rb

            ${cfg.packages.gitlab-shell}/bin/install

            ${optionalString cfg.smtp.enable ''
              install -m u=rw ${smtpSettings} ${cfg.statePath}/config/initializers/smtp_settings.rb
              ${optionalString (cfg.smtp.passwordFile != null) ''
                smtp_password=$(<'${cfg.smtp.passwordFile}')
                ${pkgs.replace}/bin/replace-literal -e '@smtpPassword@' "$smtp_password" '${cfg.statePath}/config/initializers/smtp_settings.rb'
              ''}
            ''}

            (
              umask u=rwx,g=,o=

              ${pkgs.openssl}/bin/openssl rand -hex 32 > ${cfg.statePath}/gitlab_shell_secret

              if [[ -h '${cfg.statePath}/config/database.yml' ]]; then
                rm '${cfg.statePath}/config/database.yml'
              fi

              ${if cfg.databasePasswordFile != null then ''
                  export db_password="$(<'${cfg.databasePasswordFile}')"

                  if [[ -z "$db_password" ]]; then
                    >&2 echo "Database password was an empty string!"
                    exit 1
                  fi

                  ${pkgs.jq}/bin/jq <${pkgs.writeText "database.yml" (builtins.toJSON databaseConfig)} \
                                    '.production.password = $ENV.db_password' \
                                    >'${cfg.statePath}/config/database.yml'
                ''
                else ''
                  ${pkgs.jq}/bin/jq <${pkgs.writeText "database.yml" (builtins.toJSON databaseConfig)} \
                                    >'${cfg.statePath}/config/database.yml'
                ''
              }

              ${utils.genJqSecretsReplacementSnippet
                  gitlabConfig
                  "${cfg.statePath}/config/gitlab.yml"
              }

              if [[ -h '${cfg.statePath}/config/secrets.yml' ]]; then
                rm '${cfg.statePath}/config/secrets.yml'
              fi

              export secret="$(<'${cfg.secrets.secretFile}')"
              export db="$(<'${cfg.secrets.dbFile}')"
              export otp="$(<'${cfg.secrets.otpFile}')"
              export jws="$(<'${cfg.secrets.jwsFile}')"
              ${pkgs.jq}/bin/jq -n '{production: {secret_key_base: $ENV.secret,
                                                  otp_key_base: $ENV.otp,
                                                  db_key_base: $ENV.db,
                                                  openid_connect_signing_key: $ENV.jws}}' \
                                > '${cfg.statePath}/config/secrets.yml'
            )

            initial_root_password="$(<'${cfg.initialRootPasswordFile}')"
            ${gitlab-rake}/bin/gitlab-rake gitlab:db:configure GITLAB_ROOT_PASSWORD="$initial_root_password" \
                                                               GITLAB_ROOT_EMAIL='${cfg.initialRootEmail}' > /dev/null

            # We remove potentially broken links to old gitlab-shell versions
            rm -Rf ${cfg.statePath}/repositories/**/*.git/hooks

            ${pkgs.git}/bin/git config --global core.autocrlf "input"
          '';
        in [
          "+${pkgs.writeShellScript "gitlab-pre-start-full-privileges" preStartFullPrivileges}"
          "${pkgs.writeShellScript "gitlab-pre-start" preStart}"
        ];
        ExecStart = "${cfg.packages.gitlab.rubyEnv}/bin/unicorn -c ${cfg.statePath}/config/unicorn.rb -E production";
      };

    };

    systemd.services.gitlab-mail_room = {
      enable = mkDefault cfg.incomingEmail.enable;
      after = [ "network.target" "gitlab.service" ];
      requires = [ "gitlab.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = gitlabEnv;
      path = with pkgs; [ ruby ];
      restartTriggers = with builtins; [ (
        # need a different value each time anything changes
        hashString "sha256" (toJSON gitlabConfig.production.incoming_email))
      ];
      script = ''
        ${cfg.packages.gitlab.rubyEnv}/bin/mail_room \
          -c "${cfg.statePath}/config/mail_room.yml"
      '';
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = 30;
        WorkingDirectory = "${cfg.statePath}/home";
      };
    };

  };

}
