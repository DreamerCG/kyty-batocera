import asyncio
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


PS5_DIR = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    with patch.object(sys, "path", [str(PS5_DIR / "launch"), *sys.path]):
        spec.loader.exec_module(module)
    return module


class KytyPatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.game = root / "Other Game.ps5"
        self.game.mkdir()
        self.metadata = self.game / "sce_sys" / "param.json"
        self.metadata.parent.mkdir()
        self.emulator = root / "KytyPS5-U59"
        self.patches = self.emulator / "_Patches"
        self.patches.mkdir(parents=True)
        self.patch_file = self.patches / "PPSA21567.json"
        self.patch_file.write_text("{}", encoding="utf-8")
        self.module = load_module(
            "game_patch_test", PS5_DIR / "launch" / "kyty_launch" / "game_patch.py"
        )

    def test_astro_bot_mapping_ignores_metadata_and_requires_patch(self):
        game = self.game.rename(self.game.with_name("Astro Bot.ps5"))
        self.assertEqual(
            self.module.game_patch_arguments(game, self.emulator),
            ["--game-patch", str(self.patch_file)],
        )
        self.patch_file.unlink()
        self.assertEqual(self.module.game_patch_arguments(game, self.emulator), [])

    def test_patch_for_directory_and_executable(self):
        self.metadata.write_text('{"titleId": "ppsa21567"}', encoding="utf-8")
        expected = ["--game-patch", str(self.patch_file)]
        self.assertEqual(self.module.game_patch_arguments(self.game, self.emulator), expected)
        self.assertEqual(
            self.module.game_patch_arguments(self.game / "eboot.bin", self.emulator),
            expected,
        )

    def test_content_id_and_missing_or_wrong_patch(self):
        self.metadata.write_text(
            '{"contentId": "UP9000-PPSA21567_00-ABCDEFGHIJKLMNOP"}',
            encoding="utf-8",
        )
        self.assertEqual(
            self.module.game_patch_arguments(self.game, self.emulator),
            ["--game-patch", str(self.patch_file)],
        )
        self.metadata.write_text('{"titleId": "PPSA11111"}', encoding="utf-8")
        self.assertEqual(self.module.game_patch_arguments(self.game, self.emulator), [])
        self.metadata.write_text('{"titleId": "../PPSA21567"}', encoding="utf-8")
        self.assertEqual(self.module.game_patch_arguments(self.game, self.emulator), [])

    def test_malformed_metadata_and_archive(self):
        self.metadata.write_text("{", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Métadonnées de jeu illisibles"):
            self.module.game_patch_arguments(self.game, self.emulator)
        archive = self.game / "game.zar"
        archive.write_bytes(b"archive")
        self.assertEqual(self.module.game_patch_arguments(archive, self.emulator), [])

    def test_both_backends_include_selected_patch_in_command(self):
        self.game = self.game.rename(self.game.with_name("Astro Bot.ps5"))
        executable = self.emulator / "kyty_emulator"
        executable.write_bytes(b"binary")
        (self.emulator / "u59-preset.json").write_text("{}", encoding="utf-8")

        configgen = types.ModuleType("configgen")
        configgen.Command = types.SimpleNamespace(
            Command=lambda array, env: types.SimpleNamespace(args=array, env=env)
        )
        generator = types.ModuleType("configgen.generators.Generator")
        generator.Generator = type("Generator", (), {})
        dataclasses = types.ModuleType("batocera_common.dataclasses")
        dataclasses.cached_dataclass = lambda cls: cls
        dataclasses.cached_property = property
        command = types.ModuleType("batocera_launch.command")
        command.Command = lambda args, env: types.SimpleNamespace(args=args, env=env)
        emulator = types.ModuleType("batocera_launch.emulator")
        emulator.Emulator = type("Emulator", (), {})
        modules = {
            "configgen": configgen,
            "configgen.generators": types.ModuleType("configgen.generators"),
            "configgen.generators.Generator": generator,
            "batocera_common": types.ModuleType("batocera_common"),
            "batocera_common.dataclasses": dataclasses,
            "batocera_launch": types.ModuleType("batocera_launch"),
            "batocera_launch.command": command,
            "batocera_launch.emulator": emulator,
        }
        with patch.dict(sys.modules, modules):
            generator_module = load_module(
                "patch_generator", PS5_DIR / "configgen" / "generators" / "kytyGenerator.py"
            )
            launch_module = load_module(
                "patch_plugin", PS5_DIR / "launch" / "kyty_launch" / "kyty.py"
            )

        for module, cls in (
            (generator_module, generator_module.KytyU59Generator),
            (launch_module, launch_module.KytyU59),
        ):
            with (
                self.subTest(backend=module.__name__),
                patch.object(cls, "EMULATOR_DIR", self.emulator),
                patch.object(cls, "EXECUTABLE", executable),
                patch.object(module, "_ensure_executable"),
                patch.object(module, "_config_arguments", return_value=[]),
            ):
                instance = cls()
                if module is generator_module:
                    result = instance.generate(
                        types.SimpleNamespace(name="ps5", config={}),
                        str(self.game), [], {}, [], [], "",
                    )
                else:
                    instance.rom = str(self.game)
                    instance.config = {}
                    result = asyncio.run(instance.configure())
                patch_index = result.args.index("--game-patch")
                self.assertEqual(result.args[patch_index + 1], str(self.patch_file))


class KytyResolutionTests(unittest.TestCase):
    def test_resolution_formats_and_invalid_values(self):
        configgen = types.ModuleType("configgen")
        configgen.Command = types.SimpleNamespace()
        generator = types.ModuleType("configgen.generators.Generator")
        generator.Generator = type("Generator", (), {})
        dataclasses = types.ModuleType("batocera_common.dataclasses")
        dataclasses.cached_dataclass = lambda cls: cls
        dataclasses.cached_property = property
        command = types.ModuleType("batocera_launch.command")
        command.Command = type("Command", (), {})
        emulator = types.ModuleType("batocera_launch.emulator")
        emulator.Emulator = type("Emulator", (), {})
        modules = {
            "configgen": configgen,
            "configgen.generators": types.ModuleType("configgen.generators"),
            "configgen.generators.Generator": generator,
            "batocera_common": types.ModuleType("batocera_common"),
            "batocera_common.dataclasses": dataclasses,
            "batocera_launch": types.ModuleType("batocera_launch"),
            "batocera_launch.command": command,
            "batocera_launch.emulator": emulator,
        }
        with patch.dict(sys.modules, modules):
            implementations = (
                load_module(
                    "resolution_generator",
                    PS5_DIR / "configgen" / "generators" / "kytyGenerator.py",
                ),
                load_module(
                    "resolution_plugin",
                    PS5_DIR / "launch" / "kyty_launch" / "kyty.py",
                ),
            )
        with tempfile.TemporaryDirectory() as temp_dir:
            config_file = Path(temp_dir) / "Kyty.ini"
            for module in implementations:
                for value in ("R1280X720", "1280x720"):
                    with self.subTest(module=module.__name__, value=value):
                        config_file.write_text(
                            f"[GlobalConfiguration]\nscreen_resolution={value}\n",
                            encoding="utf-8",
                        )
                        args = module._config_arguments(path=config_file)
                        self.assertEqual(
                            args[:4],
                            ["--screen-width", "1280", "--screen-height", "720"],
                        )
                with self.subTest(module=module.__name__, value="override"):
                    args = module._config_arguments(
                        {"screen_resolution": "1920x1080"}, config_file
                    )
                    self.assertEqual(
                        args[:4],
                        ["--screen-width", "1920", "--screen-height", "1080"],
                    )
                for value in ("invalid", "1280x0"):
                    with self.subTest(module=module.__name__, value=value):
                        config_file.write_text(
                            f"[GlobalConfiguration]\nscreen_resolution={value}\n",
                            encoding="utf-8",
                        )
                        with self.assertRaisesRegex(ValueError, "screen_resolution"):
                            module._config_arguments(path=config_file)


class KytyConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.emulator_dir = root / "emulator"
        self.emulator_dir.mkdir()
        self.template = self.emulator_dir / "Kyty-template.ini"
        self.template.write_bytes(b"template")
        self.xdg = root / "ps5"
        self.config_dir = self.xdg / "Kyty"
        self.launch = load_module("ps5_run", PS5_DIR / "launch" / "run.py")
        for name, value in (
            ("KYTY_DIR", self.emulator_dir),
            ("XDG_CONFIG_HOME", self.xdg),
            ("KYTY_CONFIG_DIR", self.config_dir),
        ):
            self.enterContext(patch.object(self.launch, name, value))
        self.enterContext(patch.dict(os.environ))

    def test_initializes_and_preserves_configuration(self):
        self.launch._prepare_kyty_config()
        config = self.config_dir / "Kyty.ini"
        self.assertEqual(config.read_bytes(), b"template")
        self.assertEqual(os.environ["XDG_CONFIG_HOME"], str(self.xdg))

        config.write_bytes(b"personal settings")
        self.template.unlink()
        self.launch._prepare_kyty_config()
        self.assertEqual(config.read_bytes(), b"personal settings")

    def test_portable_config_fails_before_initialization(self):
        (self.emulator_dir / "Kyty.ini").write_bytes(b"portable")
        with self.assertRaisesRegex(RuntimeError, "configuration locale"):
            self.launch._prepare_kyty_config()
        self.assertFalse(self.config_dir.exists())

    def test_missing_template_fails(self):
        self.template.unlink()
        with self.assertRaises(FileNotFoundError):
            self.launch._prepare_kyty_config()

    def test_selected_emulator_and_malformed_selection(self):
        self.assertEqual(self.launch._selected_emulator([]), "kyty")
        self.assertEqual(
            self.launch._selected_emulator(["run.py", "-emulator", "kyty-u59"]),
            "kyty-u59",
        )
        with self.assertRaisesRegex(ValueError, "non pris en charge"):
            self.launch._selected_emulator(["run.py", "-emulator", "unknown"])
        with self.assertRaisesRegex(ValueError, "Valeur manquante"):
            self.launch._selected_emulator(["run.py", "-emulator"])

    def test_u59_uses_shared_template_when_it_has_none(self):
        u59_dir = Path(self.temp.name) / "emulator-u59"
        u59_dir.mkdir()
        self.launch._prepare_kyty_config(u59_dir)
        self.assertEqual((self.config_dir / "Kyty.ini").read_bytes(), b"template")


    def test_saves_symlink_created_and_conflict_detected(self):
        saves = Path(self.temp.name) / "saves"
        with patch.object(self.launch, "SAVES_DIR", saves):
            try:
                self.launch._prepare_kyty_saves()
            except OSError as error:
                self.skipTest(f"symlink indisponible: {error}")
            link = self.emulator_dir / "_SaveData"
            self.assertTrue(saves.is_dir())
            self.assertEqual(link.resolve(), saves.resolve())
            self.launch._prepare_kyty_saves()

            link.unlink()
            link.mkdir()
            with self.assertRaisesRegex(RuntimeError, "lien symbolique"):
                self.launch._prepare_kyty_saves()


class KytyMouseTests(unittest.TestCase):
    def test_configgen_mouse_only_for_launcher(self):
        configgen = types.ModuleType("configgen")
        configgen.Command = types.SimpleNamespace()
        generators = types.ModuleType("configgen.generators")
        generator = types.ModuleType("configgen.generators.Generator")
        generator.Generator = type("Generator", (), {})
        modules = {
            "configgen": configgen,
            "configgen.generators": generators,
            "configgen.generators.Generator": generator,
        }
        with patch.dict(sys.modules, modules):
            module = load_module(
                "kyty_generator",
                PS5_DIR / "configgen" / "generators" / "kytyGenerator.py",
            )
        instance = module.KytyGenerator()
        self.assertTrue(instance.getMouseMode({}, "/roms/KYTI_CONFIG.PS5"))
        self.assertFalse(instance.getMouseMode({}, "/roms/game.elf"))
        u59 = module.KytyU59Generator()
        self.assertEqual(u59.executionDirectory({}, ""), str(module.KYTY_U59_DIR))
        self.assertEqual(u59.getHotkeysContext()["name"], "kyty-u59")

    def test_configgen_u59_applies_preset_to_direct_launch(self):
        configgen = types.ModuleType("configgen")
        configgen.Command = types.SimpleNamespace(
            Command=lambda array, env: types.SimpleNamespace(array=array, env=env)
        )
        generators = types.ModuleType("configgen.generators")
        generator = types.ModuleType("configgen.generators.Generator")
        generator.Generator = type("Generator", (), {})
        modules = {
            "configgen": configgen,
            "configgen.generators": generators,
            "configgen.generators.Generator": generator,
        }
        with patch.dict(sys.modules, modules):
            module = load_module(
                "kyty_generator_u59",
                PS5_DIR / "configgen" / "generators" / "kytyGenerator.py",
            )

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            emulator_dir = root / "KytyPS5-U59"
            emulator_dir.mkdir()
            (emulator_dir / "lib").mkdir()
            executable = emulator_dir / "kyty_emulator"
            executable.write_bytes(b"binary")
            (emulator_dir / "u59-preset.json").write_text(
                json.dumps({"KYTY_PRESET_TEST": "enabled"}), encoding="utf-8"
            )
            game = root / "game.elf"
            game.write_bytes(b"game")
            with (
                patch.object(module.KytyU59Generator, "EMULATOR_DIR", emulator_dir),
                patch.object(module.KytyU59Generator, "EXECUTABLE", executable),
                patch.object(module, "_ensure_executable"),
                patch.dict(
                    os.environ,
                    {
                        "KYTY_INHERITED": "remove",
                        "TRACY_INHERITED": "remove",
                        "KEEP_ME": "preserve",
                    },
                    clear=True,
                ),
            ):
                result = module.KytyU59Generator().generate(
                    types.SimpleNamespace(name="ps5", config=None),
                    str(game),
                    [],
                    {},
                    [],
                    [],
                    "",
                )

        self.assertIn("KYTY_PRESET_TEST", result.env)
        self.assertNotIn("KYTY_INHERITED", result.env)
        self.assertNotIn("TRACY_INHERITED", result.env)
        self.assertEqual(result.env["KEEP_ME"], "preserve")
        self.assertIn(str(emulator_dir / "lib"), result.env["LD_LIBRARY_PATH"])
        self.assertIn(str(game), result.array)

    def test_batocera_launch_mouse_only_for_launcher(self):
        dataclasses = types.ModuleType("batocera_common.dataclasses")
        dataclasses.cached_dataclass = lambda cls: cls
        dataclasses.cached_property = property
        command = types.ModuleType("batocera_launch.command")
        command.Command = type("Command", (), {})
        emulator = types.ModuleType("batocera_launch.emulator")
        emulator.Emulator = type("Emulator", (), {})
        modules = {
            "batocera_common": types.ModuleType("batocera_common"),
            "batocera_common.dataclasses": dataclasses,
            "batocera_launch": types.ModuleType("batocera_launch"),
            "batocera_launch.command": command,
            "batocera_launch.emulator": emulator,
        }
        with patch.dict(sys.modules, modules):
            module = load_module(
                "kyty_plugin", PS5_DIR / "launch" / "kyty_launch" / "kyty.py"
            )
        instance = module.Kyty()
        instance.rom = "/roms/KYTI_CONFIG.PS5"
        self.assertTrue(instance.needs_mouse)
        instance.rom = "/roms/game.elf"
        self.assertFalse(instance.needs_mouse)
        self.assertEqual(module.KytyU59().execution_path, module.KYTY_U59_DIR)


if __name__ == "__main__":
    unittest.main()
