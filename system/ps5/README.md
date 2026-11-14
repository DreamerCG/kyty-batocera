# KytyPS5 sur Batocera — première étape

Ce dossier fournit une première intégration KytyPS5 pour Batocera. Il ne
contient aucun fichier système de console ni aucune donnée de jeu.

## Contenu

- `configgen/generators/kytyGenerator.py` génère la commande de lancement pour
  l'API Configgen historique.
- `configgen/ps5launcher.py` raccorde le générateur et les valeurs par défaut
  aux API Batocera récentes et historiques.
- `launch/run.py`, `launch/kyty_launch/` et
  `launch/kyty_launch-1.0.dist-info/` fournissent le point d'entrée et le plugin
  Batocera Launch.
- `system/configs/emulationstation/es_systems_ps5.cfg` déclare le système
  EmulationStation ; `es_features_ps5.cfg` ajoute les options communes Batocera.

## Installation

Depuis un terminal SSH sur Batocera, lancer :

```sh
curl -Ls https://raw.githubusercontent.com/DreamerCG/kyty-batocera/main/install.sh | bash
```

Le script installe les fichiers Configgen/Batocera Launch et les configurations
EmulationStation dans `/userdata`, puis récupère les deux émulateurs depuis
leurs releases Linux :

- [KytyPS5/KytyPS5](https://github.com/KytyPS5/KytyPS5/releases) pour `KytyPS5`.
- [Jetsku/KytyPS5](https://github.com/Jetsku/KytyPS5/releases) pour `KytyPS5-U59`.

Les archives `Linux-x86_64.tar.gz` sont téléchargées et extraites dans leurs
dossiers respectifs sous `/userdata/system/ps5/emulator/`. Le tag de release et
son checksum sont conservés dans `.release-version` dans chaque dossier ; si
la release n'a pas changé et que les exécutables sont présents, l'archive
n'est pas retéléchargée. Le fichier temporaire utilisé pour mettre à jour ce
marqueur est également créé dans le dossier de l'émulateur. Le script conserve
les jeux et les réglages Kyty déjà
présents. Il ajoute ou met à jour dans `/userdata/system/batocera.conf` les
valeurs définies dans `temp.conf`, sans modifier les autres paramètres.
Les paquets binaires des émulateurs ne sont donc pas stockés dans ce dépôt.
Le checksum SHA-256 est vérifié avant extraction lorsque GitHub le fournit.

## Mise en place prévue sur Batocera

L'installateur effectue automatiquement les étapes suivantes :

1. Déployer l'intégration depuis `system/ps5` sous `/userdata/system/ps5`, puis
   installer les archives Linux des deux releases dans les dossiers
   `/userdata/system/ps5/emulator/KytyPS5/` et
   `/userdata/system/ps5/emulator/KytyPS5-U59/`.
2. Dans EmulationStation, sélectionner `kyty` ou `kyty-u59` pour choisir la
   version à utiliser. La release U59 fournit le `u59-preset.json` appliqué par
   son loader.
3. Charger les deux fichiers `system/configs/emulationstation/es_*_ps5.cfg`
   dans la configuration EmulationStation de Batocera.
4. Placer les jeux acquis légalement dans `/userdata/roms/ps5`.
5. Le fichier `roms/ps5/kyti_config.ps5` est une entrée de menu : la sélectionner
   ouvre `kyty_launcher` sans argument, tandis que les fichiers de jeu sont
   lancés directement par `kyty_emulator`.

Au lancement, `Kyty-template.ini` est copié dans
`/userdata/system/configs/ps5/Kyty/Kyty.ini` si ce fichier n'existe pas déjà.
Les modifications existantes sont conservées. Pour le chemin de configuration
Qt, `XDG_CONFIG_HOME` est fixé à `/userdata/system/configs/ps5`. Un fichier
`Kyty.ini` dans le répertoire de l'émulateur prendrait priorité : le lancement
est alors refusé pour éviter d'utiliser une autre configuration. L'entrée
`kyti_config.ps5` active la souris via Batocera pendant l'utilisation du lanceur.
Les résolutions enregistrées par le lanceur (par exemple `R1280X720`) et celles
choisies dans EmulationStation (par exemple `1280x720`) sont prises en charge.

Pour un jeu en répertoire ou son exécutable ELF/BIN, les loaders lisent
`sce_sys/param.json` et transmettent à Kyty le fichier
`_Patches/<PPSA>.json` de l'émulateur sélectionné s'il existe. Les cheats
activés dans ce fichier sont ainsi conservés. Pour les tests, l'entrée
`Astro Bot.ps5` utilise directement l'identifiant `PPSA21567`, sans lire
les métadonnées. Les patchs des jeux en archives
`.zar` ne sont pas encore recherchés automatiquement.

Les scripts écrivent sur `stderr` les arguments, le système et le jeu choisis,
le backend Batocera, la commande préparée et les permissions Unix des binaires.
Ils ajoutent automatiquement les bits `a+x` manquants et échouent avec un
message explicite si le binaire reste inexécutable.

Les bibliothèques Linux complémentaires peuvent être placées dans
`system/ps5/lib/` (sur Batocera : `/userdata/system/ps5/lib/`). Ce répertoire
est ajouté à `LD_LIBRARY_PATH` pour Kyty, après les chemins déjà définis. Pour
l'erreur `libbrotlidec.so.1`, fournir une bibliothèque x86-64 compatible avec
la version de Batocera, ainsi que ses éventuelles dépendances. Les bibliothèques
`libbrotlidec.so.1` et `libbrotlicommon.so.1` fournies proviennent du paquet
Debian `libbrotli1` pour amd64, qui requiert libc6 >= 2.29. Leur compatibilité
avec Batocera reste à vérifier. Vérifier les dépendances sur Batocera avec
`LD_LIBRARY_PATH=/userdata/system/ps5/lib ldd /userdata/system/ps5/emulator/KytyPS5/kyty_launcher`.

Kyty documente le lancement d'un répertoire de jeu, d'un fichier ELF ou d'une
archive `.zar`. Les extensions `.elf`, `.bin` et `.zar` sont déclarées ici pour
la première validation ; la prise en charge effective des fichiers `eboot.bin`
et des répertoires de jeux reste à tester sur Batocera.

L'intégration utilise les mécanismes de lancement Configgen et Batocera Launch,
mais reste à valider sur une version cible de Batocera. Cette première étape ne
configure pas les options graphiques propres à Kyty, les raccourcis de sortie
ni le démarrage sans interface. Elle ne contient pas de jeux ni de fichiers
système de console.
