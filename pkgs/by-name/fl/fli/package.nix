{
  lib,
  python3Packages,
  fetchFromGitHub,
}:

python3Packages.buildPythonApplication (finalAttrs: {
  pname = "flights";
  version = "0.8.4";
  pyproject = true;

  __structuredAttrs = true;

  src = fetchFromGitHub {
    owner = "punitarani";
    repo = "fli";
    tag = "v${finalAttrs.version}";
    hash = "sha256-57eAtCUXuFmOizLPliI5YVj9ZHJPL7AzxpFAU6K2lDs=";
  };

  build-system = with python3Packages; [
    hatchling
  ];

  dependencies = with python3Packages; [
    babel
    curl-cffi
    httpx
    plotext
    pydantic
    python-dotenv
    ratelimit
    tenacity
    typer
  ];

  pythonImportsCheck = [ "fli" ];

  meta = {
    description = "Find cheap flights directly from the command line";
    homepage = "https://github.com/punitarani/fli";
    changelog = "https://github.com/punitarani/fli/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ squat ];
    mainProgram = "fli";
  };
})
