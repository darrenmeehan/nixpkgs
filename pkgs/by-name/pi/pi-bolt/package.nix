{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  importNpmLock,
  nodejs,
  patchelf,
  autoPatchelfHook,
  python3,
  rsync,
  libxcb,
  ripgrep,
  fd,
  makeWrapper,
  testers,
  runCommand,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:
let
  inherit (stdenv) hostPlatform;
  version = "1.1.7";

  # The AOT engine (patched Bun + WebKit) is released as a signed binary; the
  # application is compiled from source against it. Its stamp is the release's
  # RUNTIME_STAMP (unchanged since 1.0.7).
  runtimeStamp = "9606e2f852e92ee9";
  runtimeAssets = {
    x86_64-linux = fetchurl {
      url = "https://github.com/opensec-git/Pi-Bolt/releases/download/bolt-v1.1.7/pi-bolt-runtime-linux-x64.tar.gz";
      hash = "sha256-iocH/hZxGpHTOTZFDNUKxuJm75nmnjwJ5SZlJUKi1J8=";
    };
    aarch64-linux = fetchurl {
      url = "https://github.com/opensec-git/Pi-Bolt/releases/download/bolt-v1.1.7/pi-bolt-runtime-linux-arm64.tar.gz";
      hash = "sha256-1hzHgR2dpGKF/WMbdy2EwxeO/6TLM0QTcqm6YNK3vKk=";
    };
    aarch64-darwin = fetchurl {
      url = "https://github.com/opensec-git/Pi-Bolt/releases/download/bolt-v1.1.7/pi-bolt-runtime-darwin-arm64.tar.gz";
      hash = "sha256-iXjuugx3cAmfhLK66U97t6rc6EqjbmtbNVqnwycPrBs=";
    };
  };
  runtimeSrc =
    runtimeAssets.${hostPlatform.system}
      or (throw "pi-bolt: unsupported platform ${hostPlatform.system}");
in
stdenv.mkDerivation (finalAttrs: {
  pname = "pi-bolt";
  inherit version;

  src = fetchFromGitHub {
    owner = "opensec-git";
    repo = "Pi-Bolt";
    tag = "bolt-v${version}";
    hash = "sha256-IHGSW0lApGFrwKvi5UiKt0UOlIHtj5dpWM5535rblbE=";
  };

  inherit runtimeSrc;

  npmDeps = importNpmLock { npmRoot = finalAttrs.src; };

  nativeBuildInputs = [
    nodejs
    importNpmLock.npmConfigHook
    python3
    rsync
    makeWrapper
  ]
  ++ lib.optionals hostPlatform.isLinux [
    patchelf
    autoPatchelfHook
  ];
  buildInputs = lib.optionals hostPlatform.isLinux [ libxcb ];

  npmRebuildFlags = [ "--ignore-scripts" ];

  postUnpack = ''
    mkdir -p $TMPDIR/runtime
    tar -xzf ${finalAttrs.runtimeSrc} --strip-components=1 -C $TMPDIR/runtime
    chmod -R u+w $TMPDIR/runtime
  ''
  + lib.optionalString hostPlatform.isLinux ''
    # The compile links against this, and rewriting the compiled executable
    # afterwards would damage its AOT image.
    patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} $TMPDIR/runtime/bun
  '';

  buildPhase = ''
    runHook preBuild

    npm run build:offline

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    patchShebangs scripts
    mkdir -p $out/lib $out/bin
    PIBOLT_WORK=$TMPDIR/work \
    PIBOLT_BUN=$TMPDIR/runtime/bun \
    PIBOLT_RUNTIME_STAMP=${runtimeStamp} \
      ./scripts/build-pi.sh \
        --cpu ${if hostPlatform.isDarwin then "native" else "baseline"} \
        --jit off \
        --out $out/lib/pi-bolt

    # jiti's transpile cache goes stale when pi-bolt or an extension changes and
    # Bun then segfaults loading it; disable it until upstream fixes the cache.
    makeWrapper $out/lib/pi-bolt/pi $out/bin/pi-bolt \
      --prefix PATH : ${
        lib.makeBinPath [
          ripgrep
          fd
        ]
      } \
      --set-default JITI_FS_CACHE false

    runHook postInstall
  '';

  # The executable is an AOT image: stripping or patching it damages it. Only
  # the native modules are patched.
  dontStrip = true;
  dontPatchELF = true;
  dontAutoPatchelf = true;

  postFixup = lib.optionalString hostPlatform.isLinux ''
    autoPatchelf $out/lib/pi-bolt/native
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    writableTmpDirAsHomeHook
    versionCheckHook
  ];
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgram = "${placeholder "out"}/bin/pi-bolt";
  versionCheckProgramArg = "--version";

  passthru = {
    inherit runtimeAssets;

    tests = {
      version = testers.testVersion { package = finalAttrs.finalPackage; };
      # A `--version` string alone does not prove the AOT payload was loaded:
      # the Bun runtime prints its own version too. Bun reports whether the
      # static heap image was registered.
      aot =
        runCommand "${finalAttrs.pname}-aot-image-test"
          {
            nativeBuildInputs = [ finalAttrs.finalPackage ];
            meta.timeout = 60;
          }
          ''
            output=$(HOME=$TMPDIR BUN_STATIC_HEAP_VERBOSE=1 pi-bolt --version 2>&1)
            if ! grep -q 'image registered: true' <<< "$output"; then
              echo "pi-bolt did not register its AOT image (Bun CLI fallback?):" >&2
              echo "$output" >&2
              exit 1
            fi
            touch $out
          '';
    };
    updateScript = ./update.sh;
  };

  meta = {
    description = "Ahead-of-time compiled build of the pi coding agent, built from source";
    homepage = "https://github.com/opensec-git/Pi-Bolt";
    downloadPage = "https://github.com/opensec-git/Pi-Bolt/releases";
    changelog = "https://github.com/opensec-git/Pi-Bolt/releases";
    # Pi-Bolt and Bun are MIT; the bundled WebKit is LGPL-2.0-or-later and
    # BSD-2-Clause per file (THIRD_PARTY_NOTICES.md).
    license = with lib.licenses; [
      mit
      lgpl2Plus
      bsd2
    ];
    sourceProvenance = [
      lib.sourceTypes.fromSource
      lib.sourceTypes.binaryNativeCode
    ];
    platforms = builtins.attrNames runtimeAssets;
    maintainers = [ lib.maintainers.darrenmeehan ];
    mainProgram = "pi-bolt";
  };
})
