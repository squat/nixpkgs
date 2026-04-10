{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  nix-update-script,
  python3,
  uwsgi,
}:
let
  python = python3.override {
    self = python;
    packageOverrides = final: prev: {
      django = prev.django_6;
    };
  };
in
python.pkgs.buildPythonApplication (finalAttrs: {
  pname = "linkding";
  version = "1.45.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "sissbruecker";
    repo = "linkding";
    tag = "v${finalAttrs.version}";
    hash = "sha256-iGvUKmOPL0akfR52hzSGH6wu06/WP9ygiQ/HxsmrYWg=";
  };

  build-system = with python.pkgs; [
    setuptools
  ];

  dependencies = with python.pkgs; [
    beautifulsoup4
    bleach
    bleach-allowlist
    django
    djangorestframework
    huey
    markdown
    mozilla-django-oidc
    requests
    waybackpy
  ];

  dontCheckRuntimeDeps = true;

  pyprojectAppendix = ''
    [tool.setuptools.packages.find]
    include = ["bookmarks*"]
  '';

  postPatch = ''
    echo "$pyprojectAppendix" >> pyproject.toml
  '';

  ui = buildNpmPackage {
    inherit (finalAttrs) version;

    pname = "${finalAttrs.pname}-ui";
    src = finalAttrs.src;

    npmDepsHash = "sha256-zUMgl+h0BPm9QzGi1WZG8f0tDoYk8p+Al3q6uEKXqLk=";

    installPhase = ''
      runHook preInstall
      mkdir -p $out/share/bookmarks
      mv bookmarks/static $out/share/bookmarks/static
      runHook postInstall
    '';
  };

  preBuild = ''
    cp -r ${finalAttrs.ui}/share/bookmarks/static/* bookmarks/static
  '';

  passthru.updateScript = nix-update-script {
    extraArgs = [
      "--subpackage"
      "ui"
    ];
  };

  postInstall =
    let
      pythonPath = python.pkgs.makePythonPath finalAttrs.passthru.dependencies;
    in
    ''
      mkdir -p $out/{bin,share}

      cp ./manage.py $out/bin/.manage.py
      chmod +x $out/bin/.manage.py

      makeWrapper $out/bin/.manage.py $out/bin/linkding \
        --prefix PYTHONPATH : "${pythonPath}"
      makeWrapper ${lib.getBin python.pkgs.supervisor}/bin/supervisord $out/bin/supervisord \
        --prefix PYTHONPATH : "${pythonPath}:$out/${python.sitePackages}"
      makeWrapper ${lib.getExe uwsgi} $out/bin/uwsgi \
        --prefix PYTHONPATH : "${pythonPath}:$out/${python.sitePackages}"
    '';

  meta = {
    description = "Self-hosted bookmark manager that is designed be to be minimal, fast, and easy to set up using Docker.";
    homepage = "https://linkding.link";
    changelog = "https://github.com/sissbruecker/linkding/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [
      squat
    ];
  };
})
