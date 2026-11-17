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
WORK=""
BACKUP="$DEST/system/kyty_backup_$(date +%Y%m%d_%H%M%S)_$$"
TOTAL_STEPS=7
DOWNLOAD_ATTEMPTS=5

MODE="${1:-install}"
case "$MODE" in
    install|--update) ;;
    *) echo "Usage : $0 [--update]" >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || { echo "Trop d'arguments" >&2; exit 1; }

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
    if [ -n "$WORK" ] && ! rm -rf -- "$WORK"; then
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
command -v flock >/dev/null 2>&1 || fail "flock est nécessaire pour éviter les installations simultanées"
exec 8>/tmp/kyty-install.lock || fail "création du verrou impossible"
flock -n 8 || fail "une installation Kyty est déjà en cours"
mkdir -p "$DEST/system" || fail "création du dossier système impossible"
WORK="$(mktemp -d "$DEST/system/.kyty_install_tmp.XXXXXX")" \
    || fail "création du dossier temporaire impossible"

step "Téléchargement de l'archive"
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
    system/services/dcg_kyty_update \
    "roms/ps5/Kyty Launcher.ps5" \
    temp.conf VERSION.txt; do
    [ -f "$SRC/$f" ] || fail "fichier requis absent de l'archive : $f"
done
INTEGRATION_VERSION="$(tr -d '\r\n[:space:]' < "$SRC/VERSION.txt")"
[[ "$INTEGRATION_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "VERSION.txt invalide dans l'archive"
ok "Fichiers d'intégration KytyPS5 et configurations présents"

step "Récupération des releases Linux Kyty"
bash "$SRC/system/services/dcg_kyty_update" --emulators-only-locked \
    || fail "échec de l'installation d'au moins un émulateur"

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
backup_file system/services/dcg_kyty_update
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
mkdir -p "$DEST/system/services" || fail "création du dossier des services impossible"
target_path="$DEST/system/services/dcg_kyty_update"
temp_path="$(mktemp "${target_path}.XXXXXX")" || fail "création du fichier temporaire impossible"
sed 's/\r$//' "$SRC/system/services/dcg_kyty_update" > "$temp_path" && \
    chmod a+x "$temp_path" && mv -f "$temp_path" "$target_path" \
    || { rm -f "$temp_path"; fail "installation impossible : $target_path"; }
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
CONF_PRESERVED=0
conf_set() {
    local line="$1" key="${1%%=*}" tmp_conf
    line="${line#$'\xef\xbb\xbf'}"
    key="${line%%=*}"
    case "$line" in
        *=*) ;;
        *) fail "ligne invalide dans temp.conf : $line" ;;
    esac

    if awk -v k="$key=" 'index($0, k) == 1 { found = 1 } END { exit !found }' "$BATOCERA_CONF"; then
        if [ "$MODE" = "--update" ]; then
            return 2
        fi
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
        case "$?" in
            1) CONF_UPDATED=$((CONF_UPDATED + 1)) ;;
            2) CONF_PRESERVED=$((CONF_PRESERVED + 1)) ;;
        esac
    fi
done < "$TEMP_CONF"
ok "$CONF_ADDED ligne(s) ajoutée(s), $CONF_UPDATED mise(s) à jour, $CONF_PRESERVED conservée(s) dans batocera.conf"

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
    "$DEST/system/services/dcg_kyty_update" \
    "$DEST/roms/ps5/Kyty Launcher.ps5"; do
    [ -f "$f" ] || fail "fichier installé manquant : $f"
done

if [ "$MODE" = "install" ]; then
    command -v batocera-services >/dev/null 2>&1 \
        || fail "batocera-services est nécessaire pour activer la mise à jour au démarrage"
    batocera-services enable dcg_kyty_update || fail "activation du service Kyty impossible"
    enabled_services="$(batocera-services list user)" \
        || fail "vérification des services Batocera impossible"
    printf '%s\n' "$enabled_services" | grep -Fxq 'dcg_kyty_update;*' \
        || fail "le service Kyty n'est pas activé dans Batocera"
fi

version_tmp="$(mktemp "$DEST/system/ps5/.VERSION.txt.XXXXXX")" \
    || fail "création du marqueur de version impossible"
printf '%s\n' "$INTEGRATION_VERSION" > "$version_tmp" && \
    mv -f "$version_tmp" "$DEST/system/ps5/VERSION.txt" \
    || { rm -f "$version_tmp"; fail "installation du marqueur de version impossible"; }

if [ -d "$BACKUP" ]; then
    rm -rf "$BACKUP" || fail "impossible de supprimer la sauvegarde temporaire : $BACKUP"
fi
sync
ok "Installation vérifiée"

printf '\n%s%s✔ Installation de KytyPS5 terminée !%s\n' "$B" "$G" "$N"
printf "  Jeux PS5 : ${B}%s/roms/ps5${N}\n" "$DEST"
printf "  Configuration Kyty : ${B}%s/system/configs/ps5/Kyty/Kyty.ini${N} (créée au premier lancement)\n" "$DEST"
