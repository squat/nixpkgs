{
  lib,
  fetchFromGitHub,
  fetchpatch,
  buildPythonPackage,
  installShellFiles,
  babel,
  curl-cffi,
  hatchling,
  httpx,
  plotext,
  pydantic,
  python-dotenv,
  ratelimit,
  tenacity,
  typer,
}:

buildPythonPackage (finalAttrs: {
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

  build-system = [
    hatchling
  ];

  dependencies = [
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

  nativeBuildInputs = [ installShellFiles ];

  patches = [
    # Fix regression in shell completion generation.
    (fetchpatch {
      url = "https://patch-diff.githubusercontent.com/raw/punitarani/fli/pull/130.patch";
      hash = "sha256-8NNRg/COpm0VURwKQZU87trarrfBgX21+TXexKdPLzM=";
    })
  ];

  postInstall = ''
    installShellCompletion --cmd fli \
      --bash <($out/bin/fli --show-completion bash) \
      --fish <($out/bin/fli --show-completion fish) \
      --zsh <($out/bin/fli --show-completion zsh)
  '';

  meta = {
    description = "Find cheap flights directly from the command line";
    homepage = "https://github.com/punitarani/fli";
    changelog = "https://github.com/punitarani/fli/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ squat ];
    mainProgram = "fli";
  };
})
