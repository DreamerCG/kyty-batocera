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
TOTAL_STEPS=5
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
    system/ps5/emulator/KytyPS5/kyty_emulator \
    system/ps5/emulator/KytyPS5/kyty_launcher \
    system/ps5/emulator/KytyPS5/Kyty-template.ini \
    system/ps5/emulator/KytyPS5-U59/kyty_emulator \
    system/ps5/emulator/KytyPS5-U59/kyty_launcher \
    system/ps5/emulator/KytyPS5-U59/u59-preset.json \
    system/configs/emulationstation/es_systems_ps5.cfg \
    system/configs/emulationstation/es_features_ps5.cfg \
    roms/ps5/kyti_config.ps5; do
    [ -f "$SRC/$f" ] || fail "fichier requis absent de l'archive : $f"
done
ok "Fichiers KytyPS5, profils U59 et configurations présents"

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
if [ ! -e "$DEST/roms/ps5/kyti_config.ps5" ] && [ ! -L "$DEST/roms/ps5/kyti_config.ps5" ]; then
    cp -p "$SRC/roms/ps5/kyti_config.ps5" "$DEST/roms/ps5/kyti_config.ps5" \
        || fail "installation de l'entrée du lanceur Kyty impossible"
fi
ok "Fichiers copiés ; les paramètres et jeux existants sont conservés"

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
    "$DEST/system/ps5/emulator/KytyPS5-U59/kyty_emulator" \
    "$DEST/system/configs/emulationstation/es_systems_ps5.cfg" \
    "$DEST/system/configs/emulationstation/es_features_ps5.cfg" \
    "$DEST/roms/ps5/kyti_config.ps5"; do
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
