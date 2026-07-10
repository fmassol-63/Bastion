# Bastion HA — HashiCorp Boundary + Postgres HA (etcd/Patroni/HAProxy/Keepalived)

Bastion d'accès sécurisé auto-hébergé (on-premise), basé sur **HashiCorp Boundary**, avec une base de données PostgreSQL en haute disponibilité (réplication synchrone, zéro perte de données) et un point d'entrée réseau résilient via **HAProxy + Keepalived**.

Déployé sur **3 hôtes Docker** (BASTION1, BASTION2, BASTION3), tolérant la panne d'un hôte complet.

## Architecture

```
                         ┌─────────────────────────┐
Clients ──► Boundary ───►│  Worker (BASTION3)       │
 Desktop/CLI  (SSH/TCP)  │  port 9202               │
                         └────────────┬─────────────┘
                                      │
                         ┌────────────▼─────────────┐
                         │ Boundary Controllers      │
                         │ BASTION1 + BASTION2       │
                         │ ports 9200 (API) / 9201   │
                         └────────────┬─────────────┘
                                      │
                         ┌────────────▼─────────────┐
                         │  VIP 192.168.200.110      │
                         │  (Keepalived, VRRP)       │
                         └────────────┬─────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
             HAProxy (B1)      HAProxy (B2)       HAProxy (B3)
             :6432 primary     :6432 primary      :6432 primary
             :6433 replicas    :6433 replicas      :6433 replicas
                    │                 │                 │
                    └─────────────────┼─────────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
              pg-node1          pg-node2           pg-node3
              (Patroni)         (Patroni)          (Patroni)
              Leader            Sync Standby       Replica
                    │                 │                 │
                    └────────── etcd cluster ───────────┘
                        (etcd1, etcd2, etcd3 — consensus)
```

### Répartition par hôte

| Composant                | BASTION1 (.101) | BASTION2 (.103) | BASTION3 (.105) |
|---------------------------|:---:|:---:|:---:|
| etcd                      | ✅ | ✅ | ✅ |
| Patroni + PostgreSQL      | ✅ | ✅ | ✅ |
| HAProxy                   | ✅ | ✅ | ✅ |
| Keepalived (VIP `.110`)   | ✅ MASTER (prio 150) | BACKUP (prio 100) | BACKUP (prio 50) |
| Boundary Controller       | ✅ | ✅ | — |
| Boundary Worker           | — | — | ✅ |

## Stack technique

- **etcd v3.5.15** — magasin de consensus distribué pour l'élection du leader Postgres.
- **PostgreSQL 16 + Patroni** (build maison, `Dockerfile` custom) — orchestration HA de Postgres, réplication **synchrone stricte** (`synchronous_mode_strict: true`), zéro perte de données tolérée sur panne d'un seul nœud.
- **HAProxy 2.9** — routage TCP vers le leader (`/leader`) ou les replicas (`/replica`) via les checks HTTP de l'API REST Patroni (port 8008).
- **Keepalived 2.0.20** — VIP flottante (VRRP) entre les 3 hôtes, bascule automatique en cas de panne.
- **HashiCorp Boundary** (OSS, dernière version) — bastion applicatif : controller(s) + worker, gestion des accès par cibles/rôles, sans exposer directement Postgres ni les machines cibles.

## Prérequis

- 3 hôtes Docker (Debian 12 testé), avec `docker compose` v2.
- Réseau à plat entre les 3 hôtes (ex: `192.168.200.0/24`), IPs fixes.
- Utilisateur ajouté au groupe `docker` (`sudo usermod -aG docker $USER`).
- Une IP libre sur le même sous-réseau pour la VIP Keepalived.

## Installation — étape par étape

### 1. etcd (sur les 3 hôtes)

```bash
mkdir -p ~/Bastion/BASTION<N>/etcd/data
cd ~/Bastion/BASTION<N>/etcd
docker compose up -d
```

Vérification du cluster (depuis n'importe quel hôte) :
```bash
docker exec -it etcd-1 etcdctl member list --endpoints=http://<IP>:2379
docker exec -it etcd-1 etcdctl endpoint health --cluster \
  --endpoints=http://192.168.200.101:2379,http://192.168.200.103:2379,http://192.168.200.105:2379
```

### 2. Patroni + PostgreSQL (sur les 3 hôtes)

Build maison (`postgres:16` + `patroni[etcd3]` installé via pip dans un venv).

⚠️ **Points critiques rencontrés en prod :**
- Monter le **dossier parent** (`./data:/home/postgres`), jamais `pgdata` directement en bind mount — Patroni a besoin de pouvoir **renommer** ce dossier en cas d'échec de bootstrap, ce qu'un bind mount direct interdit (`Device or resource busy`).
- Corriger les **permissions** du volume avant le premier lancement (l'utilisateur `postgres` dans l'image doit être propriétaire) :
```bash
  docker compose run --rm --entrypoint id patroni postgres   # récupère l'UID/GID
  sudo chown -R <UID>:<GID> ./data
```
- `PATRONI_SUPERUSER_PASSWORD` et `PATRONI_REPLICATION_PASSWORD` doivent être **strictement identiques sur les 3 hôtes** (comptes Postgres partagés au niveau cluster).
- La création d'utilisateurs additionnels (ex: `admin`) passe par un script `post_bootstrap` (`bootstrap.dcs.users` est déprécié depuis Patroni v4).

Vérification :
```bash
docker exec -it patroni-1 patronictl -c /config/patroni.yml list
```
Attendu : 1 `Leader`, 1 `Sync Standby` (lag 0), 1 `Replica`.

### 3. HAProxy (sur les 3 hôtes)

⚠️ **Doit tourner en `network_mode: host`**, sinon les connexions vers Postgres arrivent avec l'IP du réseau bridge Docker interne au lieu de l'IP réelle de l'hôte, ce qui casse les règles `pg_hba.conf` basées sur le sous-réseau physique.

Deux listeners TCP :
- `:6432` → primary (check `GET /leader` sur port 8008 de chaque nœud Patroni)
- `:6433` → replicas, round-robin (check `GET /replica`)
- `:7000/stats` → interface de stats HAProxy (nécessite `mode http` explicite sur ce bloc, le `mode tcp` global ne suffit pas)

### 4. Keepalived (sur les 3 hôtes)

VIP : `192.168.200.110`, `virtual_router_id 51` (identique sur les 3), priorités décroissantes (150 / 100 / 50).

⚠️ **Points critiques rencontrés en prod :**
- L'image `osixia/keepalived` ne contient pas `envsubst` → injection du mot de passe VRRP via `sed` dans un script d'entrypoint dédié.
- Le binaire est en `/usr/local/sbin/keepalived`, pas `/usr/sbin/`.
- Fichier de config attendu par défaut en `/etc/keepalived/keepalived.conf` (préciser `-f` explicitement).
- `auth_pass` est **tronqué à 8 caractères** par le protocole VRRP — garder un mot de passe de 8 caractères max.
- Le script de check ne doit **pas** chercher un process local (`pgrep haproxy` échoue, HAProxy tourne dans un autre conteneur) : utiliser un test réseau (`nc -z 127.0.0.1 6432`), lancé via un vrai shell (`/bin/sh -c '...'`) pour que les opérateurs shell soient interprétés.
- Activer `script_security` dans `global_defs` pour autoriser l'exécution du script de check.

Test de failover :
```bash
# Sur le MASTER actuel
docker compose stop keepalived
# Observer la bascule sur le BACKUP suivant
ip a | grep 192.168.200.110
```

### 5. Boundary Controller (BASTION1 + BASTION2)

- Clés KMS (root, worker-auth, recovery) générées via `openssl rand -base64 32` (la sous-commande `boundary config generate-kms-key` n'existe plus dans les versions récentes) — **identiques sur tous les controllers et le worker** (pour `worker-auth`).
- Connexion Postgres via la **VIP** (`192.168.200.110:6432`), pas un hôte fixe.
- `cap_add: [IPC_LOCK]` requis.
- `network_mode: host` requis pour les mêmes raisons que HAProxy.

Création de la base applicative (une fois, via le leader Postgres) :
```bash
docker exec -it patroni-1 psql -U postgres -c "CREATE USER boundary WITH PASSWORD '...';"
docker exec -it patroni-1 psql -U postgres -c "CREATE DATABASE boundary OWNER boundary;"
```

Initialisation du schéma (une seule fois, sur un seul controller) :
```bash
docker exec -it boundary-controller-1 boundary database init -config=/boundary/controller.hcl
```
⚠️ Affiche les identifiants admin **une seule fois** — à sauvegarder immédiatement dans un coffre-fort de mots de passe.

### 6. Boundary Worker (BASTION3)

- Même clé `worker-auth` que les controllers.
- `initial_upstreams` pointant vers les adresses **cluster** (port 9201) des controllers.
- `public_addr` = IP de l'hôte 3.

Vérification depuis un controller :
```bash
boundary workers list -addr=http://192.168.200.101:9200
```

## Utilisation

### CLI

```bash
boundary authenticate password \
  -addr=http://192.168.200.101:9200 \
  -auth-method-id=<AUTH_METHOD_ID> \
  -login-name=admin

boundary targets create tcp \
  -name="mon-service" \
  -default-port=<PORT> \
  -scope-id=<PROJECT_SCOPE_ID> \
  -address=<IP_CIBLE>

boundary connect -target-id=<TARGET_ID> -listen-port=<PORT>
```

### Boundary Desktop (interface graphique)

Boundary OSS n'a pas d'interface web d'administration intégrée (réservée à HCP Boundary / Enterprise). **Boundary Desktop** est l'application graphique officielle et gratuite permettant de lister les cibles et lancer des connexions en un clic, sans remplacer la CLI pour l'administration (utilisateurs, rôles, policies).

Téléchargement : https://developer.hashicorp.com/boundary/downloads

Configuration :
- **Cluster URL** : `http://192.168.200.101:9200` (ou `.103`)
- **Auth Method ID / Login / Password** : ceux générés à l'initialisation

## Limites connues / travaux restants

- [ ] **TLS désactivé** sur tous les listeners (`tls_disable = true`) — à activer avant toute exposition au-delà d'un réseau de confiance.
- [ ] Authentification uniquement par mot de passe — envisager OIDC/LDAP pour une gestion d'équipe.
- [ ] Un seul replica synchrone désigné à la fois (`pg-node2`) ; possibilité de forcer `synchronous_node_count: 2` pour tolérer la perte simultanée du leader **et** du replica synchrone (au prix d'une latence d'écriture accrue).
- [ ] Pas de sauvegarde automatisée (pgBackRest/Barman) mise en place — la réplication HA **n'est pas un backup** (ne protège pas d'un `DROP TABLE` ou d'une corruption logique).
- [ ] Keepalived lui-même n'est pas redondé au-delà des 3 instances déjà réparties (pas de couche supplémentaire).
- [ ] etcd à 3 nœuds tolère une seule panne simultanée (5 nœuds recommandés pour un environnement plus critique).

## Schéma des identifiants partagés entre hôtes

Les secrets suivants doivent être **strictement identiques** sur les hôtes concernés :

| Secret | Où | Pourquoi |
|---|---|---|
| `PATRONI_SUPERUSER_PASSWORD` | 3 hôtes Patroni | Compte Postgres unique partagé |
| `PATRONI_REPLICATION_PASSWORD` | 3 hôtes Patroni | Authentifie la réplication entre nœuds |
| Token etcd (`--initial-cluster-token`) | 3 hôtes etcd | Identifie le cluster |
| `VRRP_AUTH_PASS` | 3 hôtes Keepalived | Authentification VRRP (≤ 8 caractères) |
| `virtual_router_id` | 3 hôtes Keepalived | Identifiant du groupe VRRP |
| Clé KMS `worker-auth` | Controllers + Worker | Authentification mutuelle worker ↔ controller |
| Clés KMS `root` / `recovery` | Tous les controllers | Cohérence du chiffrement au repos |

## Licence / Auteur

Infrastructure personnelle — usage interne.
