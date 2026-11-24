#!/usr/bin/python3
import configparser
import json
import os
from pathlib import Path
import re
import stat
import sys

from configgen import Command
from configgen.generators.Generator import Generator
from kyty_launch.game_patch import game_patch_arguments


KYTY_DIR = Path("/userdata/system/ps5/emulator/KytyPS5")
KYTY_U59_DIR = Path("/userdata/system/ps5/emulator/KytyPS5-U59")
KYTY_EXTRA_LIB_DIR = Path("/userdata/system/ps5/lib")
KYTY_EXECUTABLE = KYTY_DIR / "kyty_emulator"
KYTY_LAUNCHER = KYTY_DIR / "kyty_launcher"
LAUNCHER_ENTRIES = {"kyty launcher.ps5", "kyti_config.ps5"}
EXECUTE_BITS = stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH

KYTY_CONFIG_FILE = Path("/userdata/system/configs/ps5/Kyty/Kyty.ini")
_CONFIG_FLAGS = (
    ("fullscreen_enabled", "--fullscreen"),
    ("hdr_enabled", "--hdr"),
    ("hide_cursor_enabled", "--hide-cursor"),
    ("stretch_enabled", "--stretch"),
    ("readback_linear_images", "--readback-linear-images"),
    ("readback_tiled_images", "--readback-tiled-images"),
    ("readback_storage_images", "--readback-storage-images"),
    ("sync_raw_image_buffers", "--sync-raw-image-buffers"),
    ("perf_overlay_enabled", "--perf-overlay"),
    ("skip_notice_screen", "--skip-notice-screen"),
    ("network_connected", "--network-connected"),
    ("psn_emulation_enabled", "--emulate-psn"),
    ("tessellation_enabled", "--tessellation"),
    ("occlusion_queries_enabled", "--occlusion-queries"),
    ("relaxed_shader_float", "--relaxed-shader-float"),
    ("shader_cache_enabled", "--shader-cache"),
    ("vulkan_validation_enabled", "--vulkan-validation"),
    ("shader_validation_enabled", "--shader-validation"),
    ("command_buffer_dump_enabled", "--command-buffer-dump"),
    ("profiler_enabled", "--profile"),
    ("pro_enabled", "--trinity"),
    ("amd_cpu_enabled", "--amd-cpu"),
    ("guest_tsc_enabled", "--guest-tsc"),
    ("renderdoc_enabled", "--rd"),
)
_CONFIG_VALUES = (
    ("screen_resolution", None),
    ("user_name", "--user-name"),
    ("user_id", "--user-id"),
    ("audio_input_device", "--mic"),
    ("controller_color", "--controller-color"),
    ("controller_speaker_volume", "--controller-volume"),
    ("controller_vibration_intensity", "--controller-vibration"),
    ("controller_keyboard_player", "--keyboard-player"),
    ("present_mode", "--present-mode"),
    ("flush_draws", "--flush-draws"),
    ("trophy_duration_seconds", "--trophy-duration"),
    ("vblank_frequency", "--vblank-frequency"),
    ("console_language", "--console-language"),
    ("shader_log_direction", "--shader-log-direction"),
    ("shader_log_folder", "--shader-log-folder"),
    ("command_buffer_dump_folder", "--command-buffer-dump-folder"),
    ("printf_direction", "--printf-direction"),
    ("printf_output_file", "--printf-output-file"),
)


def _config_arguments(config=None, path: Path = KYTY_CONFIG_FILE) -> list[str]:
    """Translate [GlobalConfiguration] into the flags kyty_launcher would pass."""
    parser = configparser.RawConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    sdl_keys = (
        "SDL_JOYSTICK_HIDAPI", "SDL_JOYSTICK_HIDAPI_PS4", "SDL_JOYSTICK_HIDAPI_PS5",
        "SDL_JOYSTICK_HIDAPI_SWITCH", "SDL_JOYSTICK_HIDAPI_XBOX",
        "SDL_JOYSTICK_HIDAPI_STEAMDECK", "SDL_GAMECONTROLLERCONFIG_FILE",
        "SDL_GAMECONTROLLERCONFIG",
    )
    previous = {key: os.environ.get(key) for key in sdl_keys}
    for key in sdl_keys:
        if key in environment:
            os.environ[key] = environment[key]
        else:
            os.environ.pop(key, None)
    try:
        parser.read(path, encoding="utf-8")
    except (OSError, configparser.Error) as error:
        _log(f"Configuration Kyty illisible ({path}): {error!r}")
    if not parser.has_section("GlobalConfiguration"):
        _log(f"Section GlobalConfiguration absente de {path}")
        parser.add_section("GlobalConfiguration")
    section = dict(parser["GlobalConfiguration"])
    known = {key for key, _ in _CONFIG_VALUES + _CONFIG_FLAGS}
    known |= {"trophy_enabled", "gpu_index", "pssr_upscaler"}
    applied = {}
    for key in sorted(known):
        value = config.get(key) if config is not None else None
        if value is not None and str(value).strip() not in ("", "auto"):
            section[key] = applied[key] = str(value).strip()
    _log(f"Options EmulationStation appliquées: {applied or 'aucune'}")

    def enabled(key: str) -> bool:
        return str(section.get(key, "false")).strip().lower() == "true"

    args: list[str] = []
    for key, option in _CONFIG_VALUES:
        value = section.get(key, "").strip()
        if not value:
            continue
        if option is None:
            resolution = re.fullmatch(r"[Rr]?([0-9]+)[xX]([0-9]+)", value)
            if not resolution or any(int(part) <= 0 for part in resolution.groups()):
                raise ValueError(f"screen_resolution invalide: {value!r}")
            width, height = resolution.groups()
            args += ["--screen-width", width, "--screen-height", height]
        else:
            args += [option, value]
    gpu_index = section.get("gpu_index", "-1").strip()
    if gpu_index.lstrip("-").isdigit() and int(gpu_index) >= 0:
        args += ["--gpu", gpu_index]
    if not enabled("trophy_enabled"):
        args.append("--no-trophy-notifications")
    for key, option in _CONFIG_FLAGS:
        if enabled(key):
            args.append(option)
    if enabled("pro_enabled"):
        upscaler = section.get("pssr_upscaler", "").strip()
        if upscaler:
            args += ["--pssr-upscaler", upscaler]
            folder = section.get(f"{upscaler.lower()}_folder", "").strip()
            if upscaler in ("DLSS", "FSR") and folder:
                args += [f"--{upscaler.lower()}-folder", folder]
    addons_dir = parser.get("Launcher", "addons_dir", fallback="").strip()
    if addons_dir:
        args += ["--addcont-dir", addons_dir]
    return args


def _log(message: str) -> None:
    print(f"[Kyty Configgen] {message}", file=sys.stderr, flush=True)


def _log_sdl_controller_config(environment: dict[str, str]) -> None:
    database = environment.get("SDL_GAMECONTROLLERCONFIG_FILE", "(undefined)")
    _log(
        "SDL passed to Kyty: "
        f"HIDAPI={environment.get('SDL_JOYSTICK_HIDAPI', '?')}, "
        f"PS4={environment.get('SDL_JOYSTICK_HIDAPI_PS4', '?')}, "
        f"PS5={environment.get('SDL_JOYSTICK_HIDAPI_PS5', '?')}, "
        f"Switch={environment.get('SDL_JOYSTICK_HIDAPI_SWITCH', '?')}, "
        f"Xbox={environment.get('SDL_JOYSTICK_HIDAPI_XBOX', '?')}, "
        f"SteamDeck={environment.get('SDL_JOYSTICK_HIDAPI_STEAMDECK', '?')}, "
        f"GameControllerDB={database}"
    )
    try:
        import ctypes
        import ctypes.util

        library_name = ctypes.util.find_library("SDL2-2.0") or ctypes.util.find_library("SDL2")
        if not library_name:
            raise OSError("SDL2 library not found")
        sdl = ctypes.CDLL(library_name)
        sdl.SDL_Init.argtypes = [ctypes.c_uint32]
        sdl.SDL_Init.restype = ctypes.c_int
        sdl.SDL_NumJoysticks.restype = ctypes.c_int
        sdl.SDL_JoystickNameForIndex.argtypes = [ctypes.c_int]
        sdl.SDL_JoystickNameForIndex.restype = ctypes.c_char_p
        sdl.SDL_JoystickGetDeviceGUIDString.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
        sdl.SDL_GameControllerMappingForDeviceIndex.argtypes = [ctypes.c_int]
        sdl.SDL_GameControllerMappingForDeviceIndex.restype = ctypes.c_void_p
        sdl.SDL_free.argtypes = [ctypes.c_void_p]
        if sdl.SDL_Init(0x2000) != 0:  # SDL_INIT_GAMECONTROLLER
            sdl.SDL_GetError.restype = ctypes.c_char_p
            raise OSError(sdl.SDL_GetError().decode("utf-8", "replace"))
        count = sdl.SDL_NumJoysticks()
        _log(f"SDL detected {count} controller(s); resolved mappings:")
        for index in range(count):
            name = sdl.SDL_JoystickNameForIndex(index)
            guid = ctypes.create_string_buffer(33)
            sdl.SDL_JoystickGetDeviceGUIDString(index, guid, len(guid))
            mapping_ptr = sdl.SDL_GameControllerMappingForDeviceIndex(index)
            mapping = ctypes.string_at(mapping_ptr).decode("utf-8", "replace") if mapping_ptr else None
            if mapping_ptr:
                sdl.SDL_free(mapping_ptr)
            _log(
                f"  {name.decode('utf-8', 'replace') if name else '?'} "
                f"GUID={guid.value.decode('ascii', 'replace')} "
                f"match={'yes' if mapping else 'no'} mapping={mapping or '(none)'}"
            )
        sdl.SDL_Quit()
    except Exception as error:
        _log(f"Resolved SDL mapping unavailable: {error}")
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def _ensure_executable(path: Path) -> None:
    try:
        current_mode = path.stat().st_mode
    except OSError as error:
        _log(f"Impossible de lire les permissions de {path}: {error!r}")
        raise

    _log(f"Permissions avant vérification: {path} mode={stat.S_IMODE(current_mode):04o}")
    if current_mode & EXECUTE_BITS != EXECUTE_BITS:
        _log(f"Ajout des permissions chmod a+x à {path}")
        try:
            path.chmod(current_mode | EXECUTE_BITS)
        except OSError as error:
            _log(f"Échec du chmod a+x sur {path}: {error!r}")
            raise

    try:
        verified_mode = path.stat().st_mode
    except OSError as error:
        _log(f"Impossible de vérifier les permissions après chmod pour {path}: {error!r}")
        raise

    _log(f"Permissions après vérification: {path} mode={stat.S_IMODE(verified_mode):04o}")
    if verified_mode & EXECUTE_BITS != EXECUTE_BITS or not os.access(path, os.X_OK):
        error = PermissionError(f"Kyty executable is not executable: {path}")
        _log(f"Vérification des permissions en échec: {error}")
        raise error


class KytyGenerator(Generator):
    EMULATOR_NAME = "kyty"
    EMULATOR_DIR = KYTY_DIR
    EXECUTABLE = KYTY_EXECUTABLE
    LAUNCHER = KYTY_LAUNCHER
    PRESET_REQUIRED = False

    def getHotkeysContext(self):
        return {"name": self.EMULATOR_NAME, "keys": {"exit": ["KEY_LEFTALT", "KEY_F4"]}}

    def getMouseMode(self, config, rom):
        return Path(rom).name.lower() in LAUNCHER_ENTRIES

    def executionDirectory(self, config, rom):
        return str(self.EMULATOR_DIR)

    def generate(
        self, system, rom, playersControllers, metadata, guns, wheels, gameResolution
    ):
        game_path = Path(rom)
        open_launcher = game_path.name.lower() in LAUNCHER_ENTRIES
        _log(
            f"Sélection: système={getattr(system, 'name', 'inconnu')!r}, "
            f"émulateur={self.EMULATOR_NAME}, jeu={str(game_path)!r}, "
            f"entrée_launcher={open_launcher}"
        )
        if not open_launcher and not game_path.exists():
            _log(f"Chemin de jeu introuvable: {game_path}")
            raise FileNotFoundError(f"{self.EMULATOR_NAME} game not found: {game_path}")
        executable = self.LAUNCHER if open_launcher else self.EXECUTABLE
        if not executable.is_file():
            _log(f"Exécutable absent: {executable}")
            raise FileNotFoundError(f"{self.EMULATOR_NAME} executable not found: {executable}")
        _ensure_executable(executable)

        command = (
            [str(executable)]
            if open_launcher
            else [
                str(executable),
                *_config_arguments(system.config),
                *game_patch_arguments(game_path, self.EMULATOR_DIR),
                "--game",
                str(game_path),
            ]
        )
        _log(f"Répertoire de travail: {self.EMULATOR_DIR}")
        _log(f"Commande préparée: {command!r}")
        environment = os.environ.copy()
        environment.update(
            {
                "SDL_JOYSTICK_HIDAPI": "1",
                "SDL_JOYSTICK_HIDAPI_PS4": "0",
                "SDL_JOYSTICK_HIDAPI_PS5": "0",
                "SDL_JOYSTICK_HIDAPI_SWITCH": "0",
                "SDL_JOYSTICK_HIDAPI_XBOX": "0",
                "SDL_JOYSTICK_HIDAPI_STEAMDECK": "0",
                "SDL_GAMECONTROLLERCONFIG_FILE": "/userdata/system/ps5/gamecontrollerdb.txt",
            }
        )
        preset = self.EMULATOR_DIR / "u59-preset.json"
        if self.PRESET_REQUIRED and not preset.is_file():
            raise FileNotFoundError(f"Preset U59 absent: {preset}")
        if preset.is_file():
            preset_values = json.loads(preset.read_text(encoding="utf-8"))
            if not isinstance(preset_values, dict) or not all(
                isinstance(key, str) and isinstance(value, str)
                for key, value in preset_values.items()
            ):
                raise ValueError(f"Preset Kyty invalide: {preset}")
            environment = {
                key: value
                for key, value in environment.items()
                if not key.startswith(("KYTY_", "TRACY_"))
            }
            environment.update(preset_values)
            _log(f"Preset U59 chargé: {preset}")
        _log_sdl_controller_config(environment)
        existing_library_path = environment.get("LD_LIBRARY_PATH")
        emulator_lib_dir = self.EMULATOR_DIR / "lib"
        environment["LD_LIBRARY_PATH"] = os.pathsep.join(
            path
            for path in (
                existing_library_path,
                str(emulator_lib_dir) if emulator_lib_dir.is_dir() else None,
                str(KYTY_EXTRA_LIB_DIR),
            )
            if path
        )
        _log(
            f"LD_LIBRARY_PATH pour {self.EMULATOR_NAME}: "
            f"{environment['LD_LIBRARY_PATH']!r}"
        )
        return Command.Command(
            array=command,
            env=environment,
        )


class KytyU59Generator(KytyGenerator):
    EMULATOR_NAME = "kyty-u59"
    EMULATOR_DIR = KYTY_U59_DIR
    EXECUTABLE = KYTY_U59_DIR / "kyty_emulator"
    LAUNCHER = KYTY_U59_DIR / "kyty_launcher"
    PRESET_REQUIRED = True
