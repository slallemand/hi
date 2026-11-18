---
title: "Chunkah : Content-Based Layering et Personnalisation des Red Hat Hardened Images"
date: 2026-11-18
type: concept
tags:
  - containers
  - oci
  - hardened-images
  - ubi
  - security
  - devsecops
  - sbom
  - coreos
---
# Chunkah : Content-Based Layering et Personnalisation des Red Hat Hardened Images

**Chunkah** est un outil de construction d'images OCI conçu à l'origine par les équipes CoreOS de Red Hat (Jonathan Lebon). Successeur de la technologie `rpm-ostree build-chunked-oci`, il permet de transformer un système de fichiers racine à plat (*flat rootfs*) en une image OCI découpée en couches logiques basées sur le contenu (*content-based layers*).

Dans l'écosystème Red Hat, Chunkah est l'utilitaire officiel (`registry.access.redhat.com/hi/chunkah:latest`) permettant d'étendre et de personnaliser les Red Hat Hardened Images sans compromettre leur compacité, leur sécurité *distroless* ni leur performance de déploiement.

---

## 1. La rupture de paradigme : Instruction-based vs Content-based Layering

### Le modèle traditionnel des Dockerfiles (Instruction-based)
Historiquement, Docker et Podman créent une couche OCI pour chaque instruction `RUN` ou `COPY` du `Containerfile`. 
* L'organisation des couches dépend de la façon dont le développeur a rédigé son fichier, et non de la nature des fichiers logiciels.
* Une modification minime dans une instruction invalide l'ensemble de la couche, forçant les registres et les nœuds à retélécharger des blocs disproportionnés.

### L'impasse du multi-stage classique sur du Distroless
Les images de type *distroless* (comme les Red Hat Hardened Images) ne contiennent ni gestionnaire de paquets (`dnf`/`rpm`), ni shell (`sh`/`bash`), et s'exécutent en non-root. Si une application requiert une bibliothèque système additionnelle (ex. `libpq` pour PostgreSQL) :

1. **L'approche par copie globale (`COPY --from=builder /target /`) :**
   * Elle injecte l'ensemble du système modifié dans **une unique couche monolithique géante (140+ Mo)**.
   * Elle casse le partage de couches (*layer caching*) avec l'image socle officielle. Chaque révision d'application oblige les nœuds OpenShift à retélécharger l'intégralité du socle.
2. **L'approche par extraction manuelle du binaire (`COPY ... libpq.so.5`) :**
   * Très fragile : oblige à tracer manuellement toutes les dépendances dynamiques transitives (`krb5`, `openldap`, `cyrus-sasl`, `libevent`...).
   * **Rupture de conformité :** La base RPM locale (`/var/lib/rpm`) n'étant pas mise à jour, les scanners de vulnérabilités et générateurs de SBOM (Syft, Clair, ACS) deviennent aveugles et ne détectent pas le composant.

---

## 2. Le fonctionnement de Chunkah

Chunkah résout ce problème en intervenant comme étape intermédiaire d'assemblage OCI :

```text
[ Base Image (Hardened) ] ──┐
                            ├─► [ Builder Stage (dnf --installroot=/target) ]
[ Builder Image (Tools) ] ──┘                 │
                                              ▼
                                   [ Rootfs à plat (/target) ]
                                              │
                                              ▼
                                   ┌───────────────────────┐
                                   │  Conteneur CHUNKAH    │
                                   │  - Découpage par RPM  │
                                   │  - Réapplication conf │
                                   └───────────────────────┘
                                              │
                                              ▼
                                   [ Image OCI en couches ] (oci:/run/src/out)
                                              │
                                              ▼
                                   [ Runtime Stage Final ] (FROM oci:out)
```

### Les mécanismes clés :
1. **Reconnaissance des composants (*Component Repos*) :** Chunkah inspecte le rootfs et interroge la base de données RPM (`rpmdb`). Il regroupe automatiquement tous les fichiers appartenant au même paquet RPM dans un même composant logique.
2. **Création de micro-couches OCI (*Chunked Layers*) :** Il assemble les composants en couches distinctes, déterministes et compressibles (typiquement 40 à 50 couches fines).
3. **Conservation des métadonnées OCI :** Grâce à l'argument `CHUNKAH_CONFIG_STR` (obtenu via `podman image inspect`), Chunkah réapplique la configuration d'exécution de l'image de base : utilisateur non-root (`UID 65532`), variables d'environnement, labels et point d'entrée.

---

## 3. Exemple de mise en œuvre (Containerfile)

Le pattern officiel documenté par Red Hat pour étendre une Hardened Image :

```dockerfile
ARG CHUNKAH_CONFIG_STR

# 1. Image socle ciblée
FROM registry.access.redhat.com/hi/python:3.14 AS base

# 2. Builder : installation du RPM dans un rootfs isolé (/target)
FROM registry.access.redhat.com/hi/python:3.14-builder AS builder
USER 0
COPY --from=base / /target/
RUN dnf install -y --installroot=/target --use-host-config \
        --nodocs --setopt=install_weak_deps=False libpq \
    && dnf clean all --installroot=/target

# 3. Chunkah : assemblage en couches OCI optimisées
FROM registry.access.redhat.com/hi/chunkah:latest AS chunked
USER 0
ARG CHUNKAH_CONFIG_STR
RUN --mount=type=bind,target=/run/src,rw \
    --mount=type=bind,from=builder,source=/target,target=/chunkah,ro \
    ["/usr/bin/chunkah", "build", "--rootfs", "/chunkah", "--output", "oci:/run/src/out"]

# 4. Runtime final : consommation de l'image générée
FROM oci:out
COPY app.py /app/
WORKDIR /app
CMD ["python3", "app.py"]
```

> **Commande de build associée :**
> ```bash
> rm -rf out
> podman build --no-cache --skip-unused-stages=false --security-opt label=disable \
>   -v $(pwd):/run/src \
>   --build-arg "CHUNKAH_CONFIG_STR=$(podman image inspect registry.access.redhat.com/hi/python:3.14)" \
>   -t custom-python-app:latest .
> ```

---

## 4. Modèle Opérationnel : La Chaîne des Responsabilités (Red Hat -> Ops -> Dev)

L'introduction de Chunkah permet de clarifier et de cloisonner les responsabilités entre l'éditeur, la plateforme interne et les développeurs :

```text
┌────────────────────────────────────────────────────────────────────────┐
│ 1. RED HAT (Éditeur)                                                   │
│    - Socle certifié 'hi/python:3.14' (Distroless, zéro shell, non-root)│
│    - Signature & SBOM officiel amont (Konflux CI / Cosign)             │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ pull
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 2. ÉQUIPE OPS / SOCLE (Plateforme d'Entreprise)                        │
│    - Injection des dépendances internes (ex: libpq, CAs) via Chunkah   │
│    - Découpage en 48 micro-couches OCI (Containerfile.ops)             │
│    - Régénération du SBOM d'entreprise (Syft) & Signature (Cosign)     │
│    - Publication de la Golden Image : 'company-python-base:3.14'       │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ registre interne
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 3. ÉQUIPE DEV (Consommation Métier)                                    │
│    - Consomme directement : FROM company-python-base:3.14              │
│    - Ajoute le code applicatif (Containerfile.dev standard)            │
│    - Aucun droit root, aucune manipulation de Chunkah ou de DNF        │
│    - Exécution sécurisée en production sur OpenShift                   │
└────────────────────────────────────────────────────────────────────────┘
```

1. **Red Hat (Éditeur) :** Garantit un socle hermétique sans shell, patché en continu, signé cryptographiquement (`cosign verify --key https://security.access.redhat.com/data/63405576.txt ...`), et fournit le SBOM certifié de la release.
2. **Équipe Ops / Plateforme :** Utilise `Containerfile.ops` avec Chunkah pour concevoir la *Golden Image* d'entreprise. Les Ops portent la responsabilité de régénérer le SBOM d'entreprise (`syft`) pour l'homologation QDS/Sécurité et signent l'image.
3. **Équipe Dev :** Rédige un simple `Containerfile.dev` (`FROM company-python-base:3.14`, `COPY app /app`). Les développeurs n'ont pas à connaître la mécanique Chunkah ni à manipuler les droits root.

---

## 5. Impact sur la Supply Chain Logicielle & le SBOM

L'utilisation de Chunkah a un impact direct sur la chaîne d'attestation de sécurité :

* **Vérification cryptographique amont (Runtime & Builder) :** Toutes les briques officielles (base runtime, image `-builder` exécutée en root, et conteneur `chunkah`) sont signées avec la clé officielle Red Hat (`https://security.access.redhat.com/data/63405576.txt`).
* **Vérification sur registre miroir interne :** Si les images sont répliquées sur un registre privé (Quay, ACR, Harbor) :
  - Il faut synchroniser les signatures associées (`cosign copy` ou mirroring du tag `sha256-<digest>.sig`).
  - L'option `--check-claims=false` doit être fournie à `cosign verify` pour valider l'intégrité du digest SHA256 sans exiger la concordance du nom d'hôte (`docker-reference` d'origine).
* **Rupture d'attestation upstream lors de la customisation :** Dès qu'un paquet est injecté via Chunkah, le digest change. Le SBOM Red Hat amont devient caduc.
* **Rôle de Chunkah pour l'audit :** Comme Chunkah maintient l'intégrité de `/var/lib/rpm`, l'image produite est parfaitement analysable par les outils d'audit d'entreprise.
* **Chaîne DevSecOps cible :** L'usine logicielle (CI/CD) doit exécuter un générateur de SBOM post-build :
  ```bash
  syft custom-python-app:latest -o spdx-json=sbom.spdx.json
  cosign attach sbom --sbom sbom.spdx.json <registry>/custom-python-app@sha256:<digest>
  cosign sign --key <cle-entreprise> <registry>/custom-python-app@sha256:<digest>
  ```

---

## 6. Arbitrage Avant-Vente : Quand recommander Chunkah ?

| Critère | Red Hat UBI (Universal Base Image) | Hardened Images + Chunkah |
| :--- | :--- | :--- |
| **Objectif de sécurité** | Stabilité long terme, compatibilité ascendante RHEL. | Vise le **Zéro CVE**, surface d'attaque minimale. |
| **Environnement runtime** | Standard (shell `bash`, `dnf`/`microdnf`, outils de base). | **Distroless** (aucun shell, aucun package manager, non-root). |
| **Complexité du build** | **Simple** (`RUN dnf install -y ...`). | **Avancée** (Multi-stage en 4 étapes avec Chunkah). |
| **Performance réseau/pull** | Standard (quelques couches de taille moyenne). | **Optimale** (Deduplication et micro-couches OCI fines). |
| **Profil client type** | Projets classiques, migration d'applications legacy. | Microservices hautement réglementés (Banque, Assurance, Défense). |

---

## Sources

* [GitHub : coreos/chunkah (Jonathan Lebon)](https://github.com/coreos/chunkah)
* [Red Hat Documentation : Build custom application images (Hardened Images 1-latest)](https://docs.redhat.com/en/documentation/red_hat_hardened_images/1-latest/develop-build_custom_application_images#GUID-a65902e9-2114-4643-a753-266c17e30ea9)
* [Red Hat Documentation : Compliance verification by using image SBOMs](https://docs.redhat.com/en/documentation/red_hat_hardened_images/1-latest/develop-sbom_and_compliance)
