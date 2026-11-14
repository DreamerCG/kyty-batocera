Bibliotheques Linux complementaires pour KytyPS5 sur Batocera.

Placer ici les bibliotheques x86-64 compatibles avec le systeme cible,
avec leurs noms SONAME et leurs dependances. Ce dossier est ajoute a
LD_LIBRARY_PATH par les lanceurs Kyty.

libbrotlidec.so.1 et libbrotlicommon.so.1 proviennent du paquet Debian
libbrotli1 1.0.9-2+deb12u1 amd64 :
https://packages.debian.org/bookworm/amd64/libbrotli1/download
SHA-256 du paquet : e27b3d655fa6fadd7a56f706687e94573c0af68b7d6df394a32a381a3a6c6d8b
Voir brotli-copyright.txt pour les licences.

Le paquet Debian requiert libc6 >= 2.29 ; sa compatibilite avec Batocera
doit encore etre verifiee sur la machine cible.
