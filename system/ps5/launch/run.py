#!/usr/bin/python3
import importlib.util
import os
from pathlib import Path
import runpy
import shutil
import sys


HERE = Path(__file__).resolve().parent
CONFIGGEN_DIR = HERE.parent / "configgen"
PS5_DEFAULTS = CONFIGGEN_DIR / "configgen-defaults.yml"
PS5_ARCH_DEFAULTS = CONFIGGEN_DIR / "configgen-defaults-arch.yml"
KYTY_DIR = HERE.parent / "emulator" / "KytyPS5"
KYTY_U59_DIR = HERE.parent / "emulator" / "KytyPS5-U59"
EMULATOR_DIRS = {"kyty": KYTY_DIR, "kyty-u59": KYTY_U59_DIR}
XDG_CONFIG_HOME = Path("/userdata/system/configs/ps5")
KYTY_CONFIG_DIR = XDG_CONFIG_HOME / "Kyty"
SAVES_DIR = Path("/userdata/saves/ps5")


def _log(message: str) -> None:
    print(f"[PS5 launch] {message}", file=sys.stderr, flush=True)


def _selected_emulator(argv: list[str]) -> str:
    if "-emulator" not in argv:
        return "kyty"
    index = argv.index("-emulator")
    if index + 1 >= len(argv):
        raise ValueError("Valeur manquante après -emulator")
    emulator = argv[index + 1]
    if emulator not in EMULATOR_DIRS:
        raise ValueError(f"Émulateur PS5 non pris en charge: {emulator}")
    return emulator


def _prepare_kyty_config(emulator_dir: Path | None = None) -> None:
    emulator_dir = emulator_dir or KYTY_DIR
    portable_config = emulator_dir / "Kyty.ini"
    if portable_config.exists():
        raise RuntimeError(
            f"Kyty utiliserait la configuration locale {portable_config} "
            f"au lieu de {KYTY_CONFIG_DIR / 'Kyty.ini'}"
        )

    KYTY_CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    config = KYTY_CONFIG_DIR / "Kyty.ini"
    if not config.exists():
        template_path = emulator_dir / "Kyty-template.ini"
        if not template_path.is_file():
            template_path = KYTY_DIR / "Kyty-template.ini"
        with template_path.open("rb") as template:
            try:
                destination = config.open("xb")
            except FileExistsError:
                if not config.is_file():
                    raise
            else:
                try:
                    with destination:
                        shutil.copyfileobj(template, destination)
                except OSError:
                    config.unlink()
                    raise
    if not config.is_file():
        raise RuntimeError(f"La configuration Kyty n'est pas un fichier: {config}")

    os.environ["XDG_CONFIG_HOME"] = str(XDG_CONFIG_HOME)
    _log(f"Configuration Kyty: {config}; XDG_CONFIG_HOME={XDG_CONFIG_HOME}")


def _prepare_kyty_saves(emulator_dir: Path | None = None) -> None:
    emulator_dir = emulator_dir or KYTY_DIR
    SAVES_DIR.mkdir(parents=True, exist_ok=True)

    link = emulator_dir / "_SaveData"
    if link.is_symlink():
        if os.readlink(link) == str(SAVES_DIR):
            return
        link.unlink()
    elif link.exists():
        raise RuntimeError(
            f"{link} existe déjà et n'est pas un lien symbolique: "
            f"déplacez son contenu dans {SAVES_DIR} puis supprimez-le"
        )
    link.symlink_to(SAVES_DIR, target_is_directory=True)
    _log(f"Sauvegardes Kyty: {link} -> {SAVES_DIR}")


def _log_runtime_environment() -> None:
    for name in (
        "HOME",
        "PATH",
        "LD_LIBRARY_PATH",
        "QT_PLUGIN_PATH",
        "QT_QPA_PLATFORM",
        "DISPLAY",
        "WAYLAND_DISPLAY",
        "XDG_RUNTIME_DIR",
    ):
        _log(f"Environnement {name}={os.environ.get(name, '<non défini>')!r}")


def _has_configgen() -> bool:
    try:
        found = importlib.util.find_spec("configgen") is not None
        _log(f"Configgen disponible: {found}")
        return found
    except (ImportError, ValueError) as error:
        _log(f"Détection Configgen impossible: {error!r}; utilisation de Batocera Launch")
        return False


def run_configgen() -> None:
    _log(f"Backend choisi: Configgen; script={CONFIGGEN_DIR / 'ps5launcher.py'}")
    _log(f"Valeurs par défaut: {PS5_DEFAULTS} (présent={PS5_DEFAULTS.is_file()})")
    _log(
        f"Valeurs par défaut architecture: {PS5_ARCH_DEFAULTS} "
        f"(présent={PS5_ARCH_DEFAULTS.is_file()})"
    )
    sys.path.insert(0, str(CONFIGGEN_DIR))
    sys.argv[0] = str(CONFIGGEN_DIR / "ps5launcher.py")
    _log(f"Arguments transmis: {sys.argv!r}")
    runpy.run_path(sys.argv[0], run_name="__main__")


def run_batocera_launch() -> None:
    _log(f"Backend choisi: Batocera Launch; plugin directory={HERE}")
    _log(f"Arguments transmis: {sys.argv!r}")
    sys.path.insert(0, str(HERE))
    from batocera_launch.config import config as config_module, defaults

    original_load_system_defaults = defaults.load_system_defaults

    def load_system_defaults(system_name: str, /):
        _log(f"Chargement des valeurs par défaut pour le système {system_name!r}")
        if (
            system_name != "ps5"
            or not PS5_DEFAULTS.exists()
            or not PS5_ARCH_DEFAULTS.exists()
        ):
            return original_load_system_defaults(system_name)

        data = defaults.load_defaults(
            system_name, PS5_DEFAULTS, PS5_ARCH_DEFAULTS
        ) or {}
        _log(f"Valeurs PS5 chargées: {data!r}")
        result = {"emulator": data.get("emulator"), "core": data.get("core")}
        result.update(data.get("options") or {})
        result["hud_support"] = True
        return result

    defaults.load_system_defaults = load_system_defaults
    config_module.load_system_defaults = load_system_defaults

    from batocera_launch.cli.main import main
    _log("Appel de batocera_launch.cli.main.main()")
    main()


if __name__ == "__main__":
    _log(f"Démarrage; Python={sys.version.split()[0]}; cwd={os.getcwd()}")
    _log(f"Entrée={Path(__file__).resolve()}")
    _log(f"Arguments reçus: {sys.argv!r}")
    _log_runtime_environment()
    emulator_name = _selected_emulator(sys.argv)
    emulator_dir = EMULATOR_DIRS[emulator_name]
    _log(f"Émulateur sélectionné: {emulator_name}; dossier={emulator_dir}")
    _prepare_kyty_config(emulator_dir)
    _prepare_kyty_saves(emulator_dir)
    if _has_configgen():
        _log("Lancement avec Configgen")
        run_configgen()
    else:
        _log("Lancement avec Batocera Launch")
        run_batocera_launch()
