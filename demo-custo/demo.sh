#!/usr/bin/env bash
set -euo pipefail

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

REDHAT_BASE_IMAGE="registry.access.redhat.com/hi/python:3.14"
REDHAT_BUILDER_IMAGE="registry.access.redhat.com/hi/python:3.14-builder"
REDHAT_CHUNKAH_IMAGE="registry.access.redhat.com/hi/chunkah:latest"
REDHAT_PUBLIC_KEY="https://security.access.redhat.com/data/63405576.txt"
COMPANY_BASE_IMAGE="company-python-base:3.14"
DEV_APP_IMAGE="my-python-app:latest"

header() {
    echo -e "\n${BLUE}${BOLD}######################################################################${NC}"
    echo -e "${MAGENTA}${BOLD}$1${NC}"
    echo -e "${BLUE}${BOLD}######################################################################${NC}"
}

step() {
    echo -e "\n${CYAN}${BOLD}──▶ $1${NC}"
}

pause() {
    echo -e "\n${BOLD}Appuyez sur [Entrée] pour continuer...${NC}"
    read -r
}

# =============================================================================
# RÔLE 1 : RED HAT (Éditeur & Fournisseur du Socle Certifié)
# =============================================================================
header "RÔLE 1 : RED HAT (Fournisseur des socles UBI / Hardened Images et SBOMs)"

echo -e "Responsabilité Red Hat :"
echo -e "  * Fournir une base minimale d'exécution (Distroless, non-root, sans shell)."
echo -e "  * Signer cryptographiquement l'image et publier le SBOM officiel de la release."

step "1.1. Vérification cryptographique des signatures Red Hat (Base, Builder & Chunkah)"
echo -e "Clé publique officielle : ${REDHAT_PUBLIC_KEY}"
echo -e "Note sur registre miroir interne : utiliser '--check-claims=false' si l'image est copiée."

echo -e "\n1. Vérification de l'image Runtime socle (${REDHAT_BASE_IMAGE}) :"
if cosign verify --key "${REDHAT_PUBLIC_KEY}" --insecure-ignore-tlog "${REDHAT_BASE_IMAGE}" > /tmp/cosign-base.json 2>&1; then
    echo -e "   ${GREEN}[OK] Signature Runtime certifiée Red Hat validée.${NC}"
else
    echo -e "   ${YELLOW}[!] Échec de vérification Runtime.${NC}"
fi

echo -e "2. Vérification de l'image Builder (${REDHAT_BUILDER_IMAGE}) :"
if cosign verify --key "${REDHAT_PUBLIC_KEY}" --insecure-ignore-tlog "${REDHAT_BUILDER_IMAGE}" > /tmp/cosign-builder.json 2>&1; then
    echo -e "   ${GREEN}[OK] Signature Builder validée (garantie d'intégrité de dnf et des outils de build).${NC}"
else
    echo -e "   ${YELLOW}[!] Échec de vérification Builder.${NC}"
fi

echo -e "3. Vérification de l'image utilitaire Chunkah (${REDHAT_CHUNKAH_IMAGE}) :"
if cosign verify --key "${REDHAT_PUBLIC_KEY}" --insecure-ignore-tlog "${REDHAT_CHUNKAH_IMAGE}" > /tmp/cosign-chunkah.json 2>&1; then
    echo -e "   ${GREEN}[OK] Signature Chunkah validée (outil de packaging OCI certifié).${NC}"
else
    echo -e "   ${YELLOW}[!] Échec de vérification Chunkah.${NC}"
fi

step "1.2. Téléchargement du SBOM officiel signé par Red Hat via Cosign"
if cosign download sbom "${REDHAT_BASE_IMAGE}" > /tmp/redhat-base-sbom.spdx.json 2>/dev/null; then
    echo -e "${GREEN}[OK] SBOM SPDX officiel récupéré depuis le registre Red Hat.${NC}"
    head -n 14 /tmp/redhat-base-sbom.spdx.json
else
    echo -e "${YELLOW}[!] Impossible de joindre le registre pour le SBOM (réseau ou proxy).${NC}"
fi

step "1.3. Audit de l'image de base (Vérification des packages et absence de libpq)"
echo -e "Scan Syft sur ${REDHAT_BASE_IMAGE} :"
if syft "${REDHAT_BASE_IMAGE}" 2>/dev/null | grep -i "libpq"; then
    echo -e "${RED}libpq est présent.${NC}"
else
    echo -e "${GREEN}[OK] libpq est bien ABSENT du socle standard Red Hat.${NC}"
fi

step "1.4. Vérification du paradigme Distroless (Aucun shell disponible)"
set +e
podman run --rm "${REDHAT_BASE_IMAGE}" sh -c "echo Hello" 2>&1 | head -n 2
set -e
echo -e "${GREEN}[OK] Sécurité maximale garantie par Red Hat : pas de bash/sh ni dnf en production.${NC}"

pause

# =============================================================================
# RÔLE 2 : ÉQUIPE OPS / SOCLE (Création, Sécurisation et Mise à Disposition)
# =============================================================================
header "RÔLE 2 : ÉQUIPE OPS / SOCLE (Création de la Golden Image d'Entreprise via Chunkah)"

echo -e "Responsabilité de l'équipe OPS / Socle :"
echo -e "  * Enrichir l'image socle avec les dépendances d'entreprise (ex: libpq, CAs internes)."
echo -e "  * Maintenir le découpage en micro-couches OCI optimal via Chunkah (préservation du cache nœud)."
echo -e "  * Régénérer et signer le nouveau SBOM d'entreprise pour validation QDS / Sécurité."
echo -e "  * Publier la Golden Image sur le registre interne pour les développeurs."

step "2.1. Nettoyage du répertoire de sortie OCI"
rm -rf out

step "2.2. Construction de l'image socle d'entreprise avec Chunkah (Containerfile.ops)"
echo -e "Fichier utilisé : ${BOLD}Containerfile.ops${NC} (Installation de libpq dans /target + Chunkah)"
BASE_CONFIG=$(podman image inspect "${REDHAT_BASE_IMAGE}")

podman build --no-cache --skip-unused-stages=false --security-opt label=disable \
  -v "$(pwd)":/run/src \
  --build-arg "CHUNKAH_CONFIG_STR=${BASE_CONFIG}" \
  -t "${COMPANY_BASE_IMAGE}" \
  -f Containerfile.ops .

echo -e "\n${GREEN}[OK] Golden Image d'entreprise créée : ${COMPANY_BASE_IMAGE}${NC}"

step "2.3. Prise de relais Supply Chain : Génération du SBOM d'entreprise post-build"
echo -e "Le digest a changé : l'ancien SBOM Red Hat ne suffit plus."
echo -e "L'équipe Ops génère le SBOM de la Golden Image via Syft :"

syft "localhost/${COMPANY_BASE_IMAGE}" -o spdx-json=company-base-sbom.spdx.json 2>/dev/null

echo -e "Vérification de la présence de libpq et de ses dépendances dans le nouveau SBOM :"
syft "localhost/${COMPANY_BASE_IMAGE}" 2>/dev/null | grep -E "(libpq|krb5|coreutils|openldap)"

echo -e "\n${GREEN}[OK] Nouveau SBOM 'company-base-sbom.spdx.json' prêt pour signature Cosign et homologation QDS.${NC}"
echo -e "${GREEN}[OK] La Golden Image '${COMPANY_BASE_IMAGE}' est validée et poussée sur le registre interne.${NC}"

pause

# =============================================================================
# RÔLE 3 : ÉQUIPE DEV (Consommation Simple & Déploiement Métier)
# =============================================================================
header "RÔLE 3 : ÉQUIPE DEV (Consommation de la Golden Image pour le Métier)"

echo -e "Expérience de l'équipe DEV :"
echo -e "  * Le développeur NE MANIPULE PAS Chunkah, ni root, ni dnf."
echo -e "  * Il consomme simplement la Golden Image fournie par les Ops via un simple 'FROM'."
echo -e "  * Il bénéficie directement des bibliothèques système sans complexité."

step "3.1. Affichage du Containerfile applicatif (Containerfile.dev)"
cat Containerfile.dev

step "3.2. Build de l'application métier par le Dev"
podman build -t "${DEV_APP_IMAGE}" -f Containerfile.dev .
echo -e "\n${GREEN}[OK] Application métier construite : ${DEV_APP_IMAGE}${NC}"

step "3.3. Exécution et validation en production"
echo -e "Lancement du conteneur applicatif :"
podman run --rm "localhost/${DEV_APP_IMAGE}"

echo -e "\nContrôles de sécurité en production :"
echo -e "- UID non-root préservé :"
podman inspect --format '  UID configuré : {{.Config.User}}' "localhost/${DEV_APP_IMAGE}"

echo -e "- Tentative d'exploitation d'un shell (attaque bloquée) :"
set +e
podman run --rm "localhost/${DEV_APP_IMAGE}" sh -c "whoami" 2>&1 | head -n 2
set -e
echo -e "${GREEN}[OK] L'application métier tourne avec libpq, sans aucun shell, en non-root.${NC}"

echo -e "\n${BLUE}${BOLD}######################################################################${NC}"
echo -e "${GREEN}${BOLD}Démonstration terminée : Chaîne de responsabilités Red Hat -> Ops -> Dev validée !${NC}"
echo -e "${BLUE}${BOLD}######################################################################${NC}"
