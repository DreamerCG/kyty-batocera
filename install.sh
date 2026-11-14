#!/bin/bash
# Installation de KytyPS5 dans Batocera.
# Usage (SSH sur Batocera) :
#   curl -Ls https://raw.githubusercontent.com/DreamerCG/kyty-batocera/main/install.sh | bash
# Pour un dépôt ou une branche différente, définir ARCHIVE_URL avant l'exécution.
# Le contenu Kyty est fusionné dans /userdata ; les autres fichiers utilisateur
# et les jeux ne sont ni supprimés ni remplacés.

set -e

REPO_URL="${ARCHIVE_URL:-https://github.com/DreamerCG/kyty-batocera/archive/refs/heads/main.tar.gz}"
DEST="/userdata"
WORK="$DEST/system/.kyty_install_tmp"
BACKUP="$DEST/system/kyty_backup_$(date +%Y%m%d_%H%M%S)_$$"
TOTAL_STEPS=7
DOWNLOAD_ATTEMPTS=5

if [ -t 1 ]; then
    B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
    B=""; G=""; R=""; Y=""; C=""; N=""
fi
STEP=0
step() { STEP=$((STEP + 1)); printf "\n${B}${C}[%s/%s]${N} ${B}%s${N}\n" "$STEP" "$TOTAL_STEPS" "$1"; }
ok()   { printf "  ${G}✔${N} %s\n" "$1"; }
warn() { printf "  ${Y}!${N} %s\n" "$1"; }
fail() { printf "\n${R}✘ ERREUR : %s${N}\n" "$1"; exit 1; }

download_archive() {
    local attempt=1
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || fail "ni curl ni wget n'est disponible pour télécharger l'archive"

    while [ "$attempt" -le "$DOWNLOAD_ATTEMPTS" ]; do
        rm -f "$WORK/archive.tar.gz"
        if command -v curl >/dev/null 2>&1; then
            curl -fsL --retry 2 --retry-delay 2 --connect-timeout 20 \
                -o "$WORK/archive.tar.gz" "$REPO_URL" || rm -f "$WORK/archive.tar.gz"
        else
            wget -q -T 30 -O "$WORK/archive.tar.gz" "$REPO_URL" || rm -f "$WORK/archive.tar.gz"
        fi

        if [ -f "$WORK/archive.tar.gz" ] \
            && ! head -n 1 "$WORK/archive.tar.gz" | grep -qF 'version https://git-lfs.github.com/spec/v1' \
            && gzip -t "$WORK/archive.tar.gz" >/dev/null 2>&1; then
            return 0
        fi

        rm -f "$WORK/archive.tar.gz"
        if [ "$attempt" -lt "$DOWNLOAD_ATTEMPTS" ]; then
            warn "Échec du téléchargement (tentative $attempt/$DOWNLOAD_ATTEMPTS), nouvel essai..."
            sleep $((attempt * 2))
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

download_url() {
    local url="$1" dest="$2" label="$3" attempt=1
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || fail "ni curl ni wget n'est disponible pour télécharger $label"

    while [ "$attempt" -le "$DOWNLOAD_ATTEMPTS" ]; do
        rm -f "$dest"
        if command -v curl >/dev/null 2>&1; then
            curl -fsL --retry 2 --retry-delay 2 --connect-timeout 20 \
                -H 'Accept: application/vnd.github+json' \
                -o "$dest" "$url" || rm -f "$dest"
        else
            wget -q -T 30 -O "$dest" "$url" || rm -f "$dest"
        fi

        if [ -s "$dest" ]; then
            return 0
        fi
        rm -f "$dest"
        if [ "$attempt" -lt "$DOWNLOAD_ATTEMPTS" ]; then
            warn "Échec du téléchargement de $label (tentative $attempt/$DOWNLOAD_ATTEMPTS), nouvel essai..."
            sleep $((attempt * 2))
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

install_emulator_release() {
    local name="$1" api_url="$2" target="$3" json_file metadata
    local release_tag asset_url digest release_digest asset_file stage version_file version_tmp actual_digest
    json_file="$WORK/$name-release.json"
    download_url "$api_url" "$json_file" "les informations de release $name" \
        || fail "impossible de récupérer la dernière release de $name"

    metadata="$(python3 - "$json_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as release_file:
    release = json.load(release_file)

assets = [
    asset
    for asset in release.get("assets", [])
    if asset.get("name", "").endswith("Linux-x86_64.tar.gz")
]
if len(assets) != 1:
    raise SystemExit("la release doit contenir exactement une archive Linux-x86_64.tar.gz")

tag = release.get("tag_name")
url = assets[0].get("browser_download_url")
digest = assets[0].get("digest") or ""
if not tag or not url:
    raise SystemExit("la release ne contient pas de tag ou d'URL de téléchargement")
print(f"{tag}\t{url}\t{digest}")
PY
    )" || fail "métadonnées de release invalides pour $name"
    IFS=$'\t' read -r release_tag asset_url digest <<< "$metadata"
    [ -n "$release_tag" ] && [ -n "$asset_url" ] \
        || fail "tag ou URL absent dans les métadonnées de release $name"
    release_digest="$digest"

    version_file="$target/.release-version"
    if [ -f "$version_file" ] \
        && [ "$(sed -n '1p' "$version_file")" = "$release_tag" ] \
        && [ "$(sed -n '2p' "$version_file")" = "$release_digest" ] \
        && [ -x "$target/kyty_emulator" ] \
        && [ -x "$target/kyty_launcher" ]; then
        ok "$name déjà à jour ($release_tag), téléchargement ignoré"
        return 0
    fi

    asset_file="$WORK/$name-Linux-x86_64.tar.gz"
    download_url "$asset_url" "$asset_file" "l'archive Linux de $name" \
        || fail "téléchargement de l'archive Linux de $name impossible"
    gzip -t "$asset_file" || fail "archive Linux invalide ou incomplète pour $name"

    if [ -n "$digest" ]; then
        case "$digest" in
            sha256:*) digest="${digest#sha256:}" ;;
            *) fail "type de checksum non pris en charge pour $name : $digest" ;;
        esac
        actual_digest="$(python3 - "$asset_file" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as archive:
    for chunk in iter(lambda: archive.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
        )" || fail "vérification SHA-256 impossible pour $name"
        [ "$actual_digest" = "$digest" ] \
            || fail "checksum SHA-256 incorrect pour l'archive de $name"
    fi

    stage="$WORK/$name"
    mkdir -p "$stage"
    tar -xzf "$asset_file" -C "$stage" \
        || fail "extraction de l'archive Linux impossible pour $name"
    for executable in kyty_emulator kyty_launcher; do
        [ -f "$stage/$executable" ] \
            || fail "binaire $executable absent de l'archive Linux de $name"
    done
    if [ "$name" = "KytyPS5-U59" ] && [ ! -f "$stage/u59-preset.json" ]; then
        fail "u59-preset.json absent de l'archive Linux de $name"
    fi

    mkdir -p "$target" || fail "création du dossier d'installation impossible : $target"
    cp -a "$stage/." "$target/" || fail "copie des fichiers de $name impossible"
    chmod a+x "$target/kyty_emulator" "$target/kyty_launcher" \
        || fail "droits d'exécution impossibles à appliquer à $name"
    [ -x "$target/kyty_emulator" ] && [ -x "$target/kyty_launcher" ] \
        || fail "les exécutables de $name ne sont pas exécutables après installation"

    version_tmp="$(mktemp "$target/.release-version.XXXXXX")" \
        || fail "création du marqueur temporaire impossible pour $name"
    printf '%s\n%s\n' "$release_tag" "$release_digest" > "$version_tmp" \
        || { rm -f "$version_tmp"; fail "écriture du marqueur de version impossible pour $name"; }
    mv -f "$version_tmp" "$version_file" \
        || { rm -f "$version_tmp"; fail "installation du marqueur de version impossible pour $name"; }
    ok "$name installé (release $release_tag)"
}

cleanup() {
    code=$?
    if ! rm -rf "$WORK"; then
        warn "Impossible de supprimer le dossier temporaire : $WORK"
    fi
    if [ "$code" -ne 0 ] && [ -d "$BACKUP" ]; then
        printf '\n%sSauvegarde conservée (installation interrompue) : %s%s\n' "$Y" "$BACKUP" "$N"
    fi
}
trap cleanup EXIT

printf '%s%s\n=========================================\n' "$B" "$C"
printf '       Installation de KytyPS5\n'
printf '=========================================%s\n' "$N"

[ -d "$DEST" ] || fail "$DEST n'existe pas (ce script doit tourner sur Batocera)"

step "Téléchargement de l'archive"
rm -rf "$WORK"
mkdir -p "$WORK" || fail "création du dossier temporaire impossible : $WORK"
download_archive || fail "téléchargement impossible après $DOWNLOAD_ATTEMPTS tentatives (vérifiez ARCHIVE_URL et la connexion)"
ok "Archive téléchargée ($(du -h "$WORK/archive.tar.gz" | cut -f1))"

step "Extraction et vérification"
tar -xzf "$WORK/archive.tar.gz" -C "$WORK" || fail "archive corrompue ou impossible à extraire"
SRC="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$SRC" ] || fail "dossier racine introuvable dans l'archive"

for f in \
    system/ps5/launch/run.py \
    system/ps5/emulator/KytyPS5/Kyty-template.ini \
    system/configs/emulationstation/es_systems_ps5.cfg \
    system/configs/emulationstation/es_features_ps5.cfg \
    "roms/ps5/Kyty Launcher.ps5" \
    temp.conf; do
    [ -f "$SRC/$f" ] || fail "fichier requis absent de l'archive : $f"
done
ok "Fichiers d'intégration KytyPS5 et configurations présents"

step "Récupération des releases Linux Kyty"
install_emulator_release \
    KytyPS5 \
    https://api.github.com/repos/KytyPS5/KytyPS5/releases/latest \
    "$DEST/system/ps5/emulator/KytyPS5"
install_emulator_release \
    KytyPS5-U59 \
    https://api.github.com/repos/Jetsku/KytyPS5/releases/latest \
    "$DEST/system/ps5/emulator/KytyPS5-U59"

step "Sauvegarde des fichiers à remplacer"
NBACKUP=0
backup_file() {
    local relative="$1"
    if [ -f "$DEST/$relative" ] && [ ! -L "$DEST/$relative" ]; then
        mkdir -p "$BACKUP/$(dirname "$relative")"
        cp -p "$DEST/$relative" "$BACKUP/$relative" \
            || fail "sauvegarde impossible : $DEST/$relative"
        NBACKUP=$((NBACKUP + 1))
    fi
}
while IFS= read -r -d '' source_file; do
    backup_file "${source_file#"$SRC"/}"
done < <(find "$SRC/system/ps5" -type f -print0)
backup_file system/configs/emulationstation/es_systems_ps5.cfg
backup_file system/configs/emulationstation/es_features_ps5.cfg
backup_file system/batocera.conf
if [ "$NBACKUP" -gt 0 ]; then
    ok "$NBACKUP fichier(s) sauvegardé(s) temporairement"
else
    ok "Première installation, rien à sauvegarder"
fi

step "Installation des fichiers KytyPS5"
mkdir -p "$DEST/system/ps5" "$DEST/system/configs/emulationstation" "$DEST/roms/ps5" \
    || fail "création des dossiers d'installation impossible"
cp -a "$SRC/system/ps5/." "$DEST/system/ps5/" \
    || fail "copie des fichiers KytyPS5 impossible"
for f in es_systems_ps5.cfg es_features_ps5.cfg; do
    cp -p "$SRC/system/configs/emulationstation/$f" \
        "$DEST/system/configs/emulationstation/$f" \
        || fail "installation de la configuration EmulationStation impossible : $f"
done
if [ ! -e "$DEST/roms/ps5/Kyty Launcher.ps5" ] && [ ! -L "$DEST/roms/ps5/Kyty Launcher.ps5" ]; then
    cp -p "$SRC/roms/ps5/Kyty Launcher.ps5" "$DEST/roms/ps5/Kyty Launcher.ps5" \
        || fail "installation de l'entrée du lanceur Kyty impossible"
fi
ok "Fichiers copiés ; les paramètres et jeux existants sont conservés"

step "Préconfiguration Batocera (batocera.conf)"
BATOCERA_CONF="$DEST/system/batocera.conf"
[ -f "$BATOCERA_CONF" ] || touch "$BATOCERA_CONF" \
    || fail "création de batocera.conf impossible"
TEMP_CONF="$SRC/temp.conf"
sed -i 's/\r$//' "$TEMP_CONF" || fail "normalisation de temp.conf impossible"
CONF_HEADER_DONE=0
CONF_ADDED=0
CONF_UPDATED=0
conf_set() {
    local line="$1" key="${1%%=*}" tmp_conf
    line="${line#$'\xef\xbb\xbf'}"
    key="${line%%=*}"
    case "$line" in
        *=*) ;;
        *) fail "ligne invalide dans temp.conf : $line" ;;
    esac

    if awk -v k="$key=" 'index($0, k) == 1 { found = 1 } END { exit !found }' "$BATOCERA_CONF"; then
        tmp_conf="$(mktemp "${BATOCERA_CONF}.XXXXXX")" \
            || fail "création du fichier temporaire pour batocera.conf impossible"
        cp -p "$BATOCERA_CONF" "$tmp_conf" \
            || fail "copie de batocera.conf impossible"
        awk -v k="$key=" -v replacement="$line" '
            index($0, k) == 1 { print replacement; next }
            { print }
        ' "$BATOCERA_CONF" > "$tmp_conf" \
            || { rm -f "$tmp_conf"; fail "mise à jour de batocera.conf impossible"; }
        mv "$tmp_conf" "$BATOCERA_CONF" \
            || { rm -f "$tmp_conf"; fail "remplacement de batocera.conf impossible"; }
        return 1
    fi

    if [ -s "$BATOCERA_CONF" ] && [ -n "$(tail -c 1 "$BATOCERA_CONF")" ]; then
        printf '\n' >> "$BATOCERA_CONF" || fail "écriture dans batocera.conf impossible"
    fi
    if [ "$CONF_HEADER_DONE" != 1 ]; then
        printf '\n# KytyPS5 configuration (install KytyPS5)\n' >> "$BATOCERA_CONF" \
            || fail "écriture de l'en-tête dans batocera.conf impossible"
        CONF_HEADER_DONE=1
    fi
    printf '%s\n' "$line" >> "$BATOCERA_CONF" \
        || fail "écriture de batocera.conf impossible"
}

while IFS= read -r line || [ -n "$line" ]; do
    line="${line#$'\xef\xbb\xbf'}"
    case "$line" in ''|\#*) continue ;; esac
    if conf_set "$line"; then
        CONF_ADDED=$((CONF_ADDED + 1))
    else
        CONF_UPDATED=$((CONF_UPDATED + 1))
    fi
done < "$TEMP_CONF"
ok "$CONF_ADDED ligne(s) ajoutée(s), $CONF_UPDATED mise(s) à jour dans batocera.conf"

step "Droits, dossiers et vérification"
find "$DEST/system/ps5" -type f -name '*.py' -exec sed -i 's/\r$//' {} + \
    || fail "normalisation des fins de ligne Python impossible"
for f in \
    "$DEST/system/ps5/emulator/KytyPS5/kyty_emulator" \
    "$DEST/system/ps5/emulator/KytyPS5/kyty_launcher" \
    "$DEST/system/ps5/emulator/KytyPS5-U59/kyty_emulator" \
    "$DEST/system/ps5/emulator/KytyPS5-U59/kyty_launcher"; do
    chmod a+x "$f" || fail "impossible d'appliquer les droits d'exécution à $f"
done
for f in \
    "$DEST/system/configs/emulationstation/es_systems_ps5.cfg" \
    "$DEST/system/configs/emulationstation/es_features_ps5.cfg"; do
    sed -i 's/\r$//' "$f" || fail "normalisation des fins de ligne impossible : $f"
done

for f in \
    "$DEST/system/ps5/launch/run.py" \
    "$DEST/system/ps5/emulator/KytyPS5/kyty_emulator" \
    "$DEST/system/ps5/emulator/KytyPS5/kyty_launcher" \
    "$DEST/system/ps5/emulator/KytyPS5/.release-version" \
    "$DEST/system/ps5/emulator/KytyPS5-U59/kyty_emulator" \
    "$DEST/system/ps5/emulator/KytyPS5-U59/kyty_launcher" \
    "$DEST/system/ps5/emulator/KytyPS5-U59/u59-preset.json" \
    "$DEST/system/ps5/emulator/KytyPS5-U59/.release-version" \
    "$DEST/system/configs/emulationstation/es_systems_ps5.cfg" \
    "$DEST/system/configs/emulationstation/es_features_ps5.cfg" \
    "$DEST/roms/ps5/Kyty Launcher.ps5"; do
    [ -f "$f" ] || fail "fichier installé manquant : $f"
done

if [ -d "$BACKUP" ]; then
    rm -rf "$BACKUP" || fail "impossible de supprimer la sauvegarde temporaire : $BACKUP"
fi
sync
ok "Installation vérifiée"

printf '\n%s%s✔ Installation de KytyPS5 terminée !%s\n' "$B" "$G" "$N"
printf "  Jeux PS5 : ${B}%s/roms/ps5${N}\n" "$DEST"
printf "  Configuration Kyty : ${B}%s/system/configs/ps5/Kyty/Kyty.ini${N} (créée au premier lancement)\n" "$DEST"
