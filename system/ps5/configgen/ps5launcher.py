#!/usr/bin/python3
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


CONFIGGEN_DIR = Path(__file__).resolve().parent
PS5_DEFAULTS = CONFIGGEN_DIR / "configgen-defaults.yml"
PS5_ARCH_DEFAULTS = CONFIGGEN_DIR / "configgen-defaults-arch.yml"
sys.path.insert(0, str(CONFIGGEN_DIR.parent / "launch"))


def _log(message: str) -> None:
    print(f"[PS5 Configgen launcher] {message}", file=sys.stderr, flush=True)


def _detect_batocera_version() -> int | None:
    _log("Détection de la version Batocera avec batocera-es-swissknife --version")
    try:
        result = subprocess.run(
            ["batocera-es-swissknife", "--version"],
            capture_output=True,
            text=True,
            check=True,
        )
        _log(
            "Résultat de détection Batocera: "
            f"returncode={result.returncode}, stdout={result.stdout.strip()!r}, "
            f"stderr={result.stderr.strip()!r}"
        )
    except (OSError, subprocess.CalledProcessError) as error:
        _log(
            "Version Batocera indisponible "
            f"({error!r}); sélection de l'API Configgen historique"
        )
        return None

    match = re.search(r"^\s*(\d+)", result.stdout)
    version = int(match.group(1)) if match else None
    _log(f"Version Batocera détectée: {version!r}")
    return version


def run_new_api() -> None:
    import runpy

    _log("Initialisation Configgen / Batocera Launch (API récente)")
    from generators.kytyGenerator import KytyGenerator, KytyU59Generator

    import configgen.generators.importer

    original_get_generator = configgen.generators.importer.get_generator

    def get_generator(emulator: str, core: str | None = None):
        _log(f"Résolution du générateur: emulator={emulator!r}, core={core!r}")
        if emulator in ("kyty", "kyty-u59"):
            generator = KytyU59Generator if emulator == "kyty-u59" else KytyGenerator
            _log(f"Générateur {generator.__name__} sélectionné")
            return generator()
        return original_get_generator(emulator, core)

    configgen.generators.importer.get_generator = get_generator

    try:
        import configgen.launch

        configgen.launch.get_generator = get_generator
    except ImportError as error:
        _log(f"Module configgen.launch indisponible: {error!r}")

    try:
        import configgen.emulatorlauncher

        configgen.emulatorlauncher.get_generator = get_generator
    except ImportError as error:
        _log(f"Module configgen.emulatorlauncher indisponible: {error!r}")

    from batocera_launch.config import config as config_module, defaults

    original_load_system_defaults = defaults.load_system_defaults

    def load_system_defaults(system_name: str):
        _log(f"Chargement des valeurs par défaut pour {system_name!r}")
        if (
            system_name == "ps5"
            and PS5_DEFAULTS.exists()
            and PS5_ARCH_DEFAULTS.exists()
        ):
            data = defaults.load_defaults(
                system_name, PS5_DEFAULTS, PS5_ARCH_DEFAULTS
            ) or {}
            _log(f"Valeurs par défaut PS5: {data!r}")
            result = {"emulator": data.get("emulator"), "core": data.get("core")}
            result.update(data.get("options") or {})
            result["hud_support"] = True
            return result

        result = original_load_system_defaults(system_name)
        result["hud_support"] = True
        return result

    defaults.load_system_defaults = load_system_defaults
    config_module.load_system_defaults = load_system_defaults
    _log("Délégation à batocera_launch")
    runpy.run_module("batocera_launch", run_name="__main__")


def run_old_api() -> None:
    _log("Initialisation Configgen historique")
    import configgen
    from configgen.Emulator import _dict_merge, _load_defaults
    from configgen.batoceraPaths import DEFAULTS_DIR
    from configgen.emulatorlauncher import launch
    from configgen.generators import get_generator

    def ps5_get_generator(emulator: str, core: str | None = None):
        _log(f"Résolution du générateur: emulator={emulator!r}, core={core!r}")
        if emulator == "kyty":
            from generators.kytyGenerator import KytyGenerator

            _log("Générateur KytyGenerator sélectionné")
            return KytyGenerator()
        if emulator == "kyty-u59":
            from generators.kytyGenerator import KytyU59Generator

            _log("Générateur KytyU59Generator sélectionné")
            return KytyU59Generator()
        return get_generator(emulator, core)

    def load_system_config(system_name: str, /) -> dict[str, Any]:
        _log(f"Chargement des valeurs par défaut pour {system_name!r}")
        if (
            system_name == "ps5"
            and PS5_DEFAULTS.exists()
            and PS5_ARCH_DEFAULTS.exists()
        ):
            defaults = _load_defaults(
                system_name, PS5_DEFAULTS, PS5_ARCH_DEFAULTS
            )
        else:
            defaults = _load_defaults(
                system_name,
                DEFAULTS_DIR / "configgen-defaults.yml",
                DEFAULTS_DIR / "configgen-defaults-arch.yml",
            )

        defaults.setdefault("options", {})["hud_support"] = True
        data: dict[str, Any] = {
            "emulator": defaults.get("emulator"),
            "core": defaults.get("core"),
        }
        if "options" in defaults:
            _dict_merge(data, defaults["options"])
        _log(f"Configuration système résolue: {data!r}")
        return data

    configgen.emulatorlauncher.get_generator = ps5_get_generator
    configgen.Emulator._load_system_config = load_system_config

    sys.argv[0] = re.sub(r"(-script\.pyw|\.exe)?$", "", sys.argv[0])
    _log(f"Arguments transmis à Configgen: {sys.argv!r}")
    _log("Délégation à configgen.emulatorlauncher.launch()")
    sys.exit(launch())


if __name__ == "__main__":
    version = _detect_batocera_version()
    if version is not None and version >= 44:
        _log("API sélectionnée: récente (Batocera 44 ou ultérieure)")
        run_new_api()
    else:
        _log("API sélectionnée: historique")
        run_old_api()
