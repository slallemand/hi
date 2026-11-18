# Démonstration Red Hat Hardened Images : Personnalisation avec Chunkah & Responsabilités (Red Hat / Ops / Dev)

Ce banc de démonstration illustre la répartition des rôles et des responsabilités autour de l'utilisation et de l'extension des **Red Hat Hardened Images** minimales (*distroless*) en entreprise, l'optimisation des couches OCI via **Chunkah**, et la gestion de la chaîne de confiance **SBOM** (Supply Chain Security).

---

## 1. La Chaîne des Responsabilités

```text
┌────────────────────────────────────────────────────────────────────────┐
│ 1. RED HAT (Éditeur)                                                   │
│    - Socle certifié 'hi/python:3.14' (Distroless, zéro shell, non-root)│
│    - Signature & SBOM officiel (Konflux CI / Cosign)                   │
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
│    - Ajoute le code métier (Containerfile.dev + example.py)            │
│    - Aucun droit root, aucune manipulation de Chunkah ou de DNF        │
│    - Exécution sécurisée en production sur OpenShift                   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Prérequis locaux

* **Podman** (`podman machine start`)
* **Syft**
* **Cosign**

---

## 3. Lancement rapide de la démo

Un script interactif pas-à-pas est fourni :

```bash
./demo.sh
```

---

## 4. Détail des étapes du workflow

### Rôle 1 : Red Hat (Éditeur)
* **Vérification cryptographique de la signature :** Validation de l'intégrité et de la provenance avec Cosign contre la clé publique officielle Red Hat :
  ```bash
  cosign verify \
    --key "https://security.access.redhat.com/data/63405576.txt" \
    --insecure-ignore-tlog \
    registry.access.redhat.com/hi/python:3.14
  ```
* **Garantie :** Image minimale hermétique (`registry.access.redhat.com/hi/python:3.14`), non-root (`UID 65532`), aucun shell interactif (`sh` / `bash` absents).
* **SBOM officiel :** Rapatrié via Cosign (`cosign download sbom registry.access.redhat.com/hi/python:3.14`).

### Rôle 2 : Équipe Ops / Socle (Golden Image avec Chunkah)
* **Problème :** L'application a besoin du driver `libpq`. Impossible de faire `dnf install` dans une image distroless.
* **Solution :** L'équipe Ops utilise `Containerfile.ops` avec l'étape `chunkah` :
  ```bash
  rm -rf out
  podman build --no-cache --skip-unused-stages=false --security-opt label=disable \
    -v "$(pwd)":/run/src \
    --build-arg "CHUNKAH_CONFIG_STR=$(podman image inspect registry.access.redhat.com/hi/python:3.14)" \
    -t company-python-base:3.14 \
    -f Containerfile.ops .
  ```
* **Chaîne d'attestation SBOM :** L'équipe Ops prend le relais de la responsabilité en auditant la Golden Image via `syft` :
  ```bash
  syft localhost/company-python-base:3.14 -o spdx-json=company-base-sbom.spdx.json
  ```
  `libpq` et ses dépendances (`krb5`, `openldap`, `coreutils`) sont tracés dans la nomenclature d'entreprise prête à être signée via Cosign.

### Rôle 3 : Équipe Dev (Consommation simple)
* Le développeur ne voit aucune complexité système. Il utilise un `Containerfile.dev` standard :
  ```dockerfile
  FROM company-python-base:3.14
  COPY example.py /app/
  WORKDIR /app
  CMD ["python3", "example.py"]
  ```
* **Build et Run applicatif :**
  ```bash
  podman build -t my-python-app:latest -f Containerfile.dev .
  podman run --rm localhost/my-python-app:latest
  ```
* **Résultat :** `example.py` charge dynamiquement `libpq.so.5` avec succès, tout en restant strictement non-root et sans shell utilisable pour une attaque.
