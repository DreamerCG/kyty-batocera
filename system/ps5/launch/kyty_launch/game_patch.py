import json
from pathlib import Path
import re
import sys


GAME_TITLE_IDS = {"astro bot.ps5": "PPSA21567"}


def game_patch_arguments(game: Path, emulator_dir: Path) -> list[str]:
    patches = emulator_dir / "_Patches"
    if not patches.is_dir():
        return []
    title_id = GAME_TITLE_IDS.get(game.name.casefold())
    if title_id:
        print(f"[Kyty patch] Mapping de test: {game.name} -> {title_id}", file=sys.stderr)
    else:
        if game.is_file() and game.suffix.lower() == ".zar":
            print(f"[Kyty patch] Patch non recherché pour l'archive ZArchive: {game}", file=sys.stderr)
            return []
        game_dir = game if game.is_dir() else game.parent
        metadata = game_dir / "sce_sys" / "param.json"
        if not metadata.is_file():
            print(f"[Kyty patch] Métadonnées absentes: {metadata}", file=sys.stderr)
            return []
        try:
            data = json.loads(metadata.read_text(encoding="utf-8-sig"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise ValueError(f"Métadonnées de jeu illisibles: {metadata}") from error
        if not isinstance(data, dict):
            raise ValueError(f"Métadonnées de jeu invalides: {metadata}")
        title_id = data.get("titleId")
        if not title_id:
            content_id = data.get("contentId")
            if (
                isinstance(content_id, str)
                and len(content_id) == 36
                and content_id[6] == "-"
                and content_id[16] == "_"
            ):
                title_id = content_id[7:16]
        if not isinstance(title_id, str) or not re.fullmatch(
            r"PPSA[0-9]{5}", title_id.strip(), re.IGNORECASE
        ):
            print(f"[Kyty patch] Identifiant PPSA absent ou invalide: {metadata}", file=sys.stderr)
            return []
    patch = patches / f"{title_id.strip().upper()}.json"
    if not patch.is_file():
        print(f"[Kyty patch] Aucun patch pour {title_id}: {patch}", file=sys.stderr)
        return []
    print(f"[Kyty patch] Patch du jeu: {patch}", file=sys.stderr)
    return ["--game-patch", str(patch)]
