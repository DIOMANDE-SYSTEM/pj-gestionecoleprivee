-- =====================================================================
-- PERROQUET JUNIOR — Schéma PostgreSQL / Supabase (cible §3 et §4 du CDC)
-- Version 1.0 — novembre 2026
--
-- Contenu : types, tables, contraintes d'intégrité, fonctions de périmètre,
-- politiques RLS (Row Level Security), déclencheurs d'audit chaîné,
-- règles de workflow (notes, bulletins, promotions), fonctions de calcul.
--
-- Prérequis Supabase : schéma "auth" (auth.users, auth.uid()) fourni par la
-- plateforme. Exécuter ce script dans l'éditeur SQL du projet (rôle postgres).
-- IMPORTANT : à valider en préproduction par des tests d'accès par rôle
-- (voir section 14 « Tests de recette » du CDC) avant toute mise en production.
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------- 1. Types ----------
do $$ begin
  create type role_code as enum ('superadmin','deps','drenaet','fondateur','directeur','secretariat','intendant','bibliothecaire','archiviste','enseignant');
exception when duplicate_object then null; end $$;
do $$ begin create type note_etat   as enum ('note','absent','dispense');            exception when duplicate_object then null; end $$;
do $$ begin create type eval_statut as enum ('brouillon','soumis','valide');         exception when duplicate_object then null; end $$;
do $$ begin create type insc_statut as enum ('inscrit','reintegre','transfere','sorti','annulee'); exception when duplicate_object then null; end $$;
do $$ begin create type decision_statut as enum ('propose','valide','annule');       exception when duplicate_object then null; end $$;

-- ---------- 2. Organisation ----------
create table if not exists regions (
  id uuid primary key default gen_random_uuid(), nom text not null unique,
  created_at timestamptz not null default now());
create table if not exists drenaet (
  id uuid primary key default gen_random_uuid(), nom text not null unique,
  region_id uuid not null references regions(id), created_at timestamptz not null default now());
create table if not exists fondateurs (
  id uuid primary key default gen_random_uuid(), nom text not null, telephone text, email text,
  created_at timestamptz not null default now());
create table if not exists etablissements (
  id uuid primary key default gen_random_uuid(),
  code text not null unique, nom text not null,
  statut text, autorisation text,
  region_id uuid not null references regions(id), drenaet_id uuid not null references drenaet(id),
  commune text, adresse text, contacts text, directeur text,
  cycles smallint[] not null default '{1}' check (cycles <@ array[1,2]::smallint[] and cardinality(cycles) > 0),
  capacite int check (capacite > 0),
  actif boolean not null default true,
  params jsonb not null default '{"seuil":10,"formule":"notees","poids":{"Interrogation":1,"Devoir":1,"Composition":2},"bulletins_roles":["professeur_principal","deps","drenaet"],"decisions":["Admis","Redoublant","Ajourné","Orienté","Autre"],"tranches":[40,30,30],"echeances":["10-31","01-31","04-30"]}',
  created_at timestamptz not null default now());
create table if not exists fondateur_etablissements (
  fondateur_id uuid not null references fondateurs(id), etablissement_id uuid not null references etablissements(id),
  primary key (fondateur_id, etablissement_id));
create table if not exists annees_scolaires (
  id uuid primary key default gen_random_uuid(), libelle text not null unique check (libelle ~ '^\d{4}-\d{4}$'),
  courante boolean not null default false);
create unique index if not exists ux_annee_courante on annees_scolaires (courante) where courante;

-- ---------- 3. Identité et accès ----------
create table if not exists utilisateurs (
  id uuid primary key references auth.users(id) on delete restrict,
  login text not null unique, nom text not null, role role_code not null,
  etablissement_id uuid references etablissements(id),
  drenaet_id uuid references drenaet(id), fondateur_id uuid references fondateurs(id),
  matieres text[] not null default '{}',
  actif boolean not null default true,
  created_at timestamptz not null default now(),
  -- le rattachement doit correspondre au rôle
  check ( (role in ('superadmin','deps')) or
          (role = 'drenaet'  and drenaet_id is not null) or
          (role = 'fondateur' and fondateur_id is not null) or
          (role not in ('superadmin','deps','drenaet','fondateur') and etablissement_id is not null) ));
create table if not exists role_permissions (role role_code not null, module text not null, action char(1) not null check (action in ('L','C','M','V','X','A')), primary key (role, module, action));
-- Dérogations individuelles (ajout ou retrait), limitables à un établissement et/ou une année
create table if not exists user_permissions (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references utilisateurs(id),
  module text not null, action char(1) not null check (action in ('L','C','M','V','X','A')),
  etablissement_id uuid references etablissements(id), annee_id uuid references annees_scolaires(id),
  granted boolean not null default true);
create table if not exists appareils (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references utilisateurs(id),
  libelle text, empreinte text not null, autorise boolean not null default true, dernier_acces timestamptz,
  unique (user_id, empreinte));
create table if not exists sessions_app (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references utilisateurs(id),
  appareil_id uuid references appareils(id), debut timestamptz not null default now(), fin timestamptz, expire_a timestamptz not null);

-- ---------- 4. Référentiels pédagogiques ----------
create table if not exists niveaux (id text primary key, nom text not null, cycle smallint not null check (cycle in (1,2)), ordre smallint not null unique, suivant text references niveaux(id));
create table if not exists matieres (code text primary key, nom text not null, actif boolean not null default true);
create table if not exists types_evaluations (code text primary key, poids numeric(4,2) not null default 1 check (poids > 0));

-- ---------- 5. Scolarité ----------
create table if not exists classes (
  id uuid primary key default gen_random_uuid(),
  etablissement_id uuid not null references etablissements(id), annee_id uuid not null references annees_scolaires(id),
  niveau_id text not null references niveaux(id), nom text not null, capacite int not null check (capacite > 0), salle text,
  prof_principal_id uuid references utilisateurs(id),
  supprime_le timestamptz,
  unique (etablissement_id, annee_id, nom));
create table if not exists eleves (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  matricule text not null, nom text not null, prenoms text not null, sexe char(1) not null check (sexe in ('F','M')),
  date_naissance date not null, lieu_naissance text, etablissement_origine text, photo_path text,
  pieces jsonb not null default '{}', supprime_le timestamptz,
  unique (etablissement_id, matricule));
create table if not exists responsables_legaux (
  id uuid primary key default gen_random_uuid(), eleve_id uuid not null references eleves(id),
  nom text not null, lien text, telephone text, email text);
create table if not exists inscriptions (
  id uuid primary key default gen_random_uuid(),
  etablissement_id uuid not null references etablissements(id), annee_id uuid not null references annees_scolaires(id),
  eleve_id uuid not null references eleves(id), classe_id uuid not null references classes(id),
  statut insc_statut not null default 'inscrit', source text, date_inscription date not null default current_date,
  date_fin date, motif text, depuis_inscription_id uuid references inscriptions(id));
-- un élève : au plus une inscription active par année scolaire
create unique index if not exists ux_insc_active on inscriptions (eleve_id, annee_id) where statut in ('inscrit','reintegre');
create table if not exists affectations (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  annee_id uuid not null references annees_scolaires(id), enseignant_id uuid not null references utilisateurs(id),
  classe_id uuid not null references classes(id), matiere_code text not null references matieres(code),
  supprime_le timestamptz, unique (classe_id, matiere_code));
-- Coefficients versionnés par année scolaire et niveau (matières « prises en compte » pour la classe)
create table if not exists coefficients (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  annee_id uuid not null references annees_scolaires(id), niveau_id text not null references niveaux(id),
  matiere_code text not null references matieres(code), coef numeric(4,1) not null check (coef >= 0),
  unique (etablissement_id, annee_id, niveau_id, matiere_code));

-- ---------- 6. Évaluations, notes, résultats ----------
create table if not exists evaluations (
  id uuid primary key default gen_random_uuid(),
  etablissement_id uuid not null references etablissements(id), annee_id uuid not null references annees_scolaires(id),
  classe_id uuid not null references classes(id), matiere_code text not null references matieres(code),
  type text not null references types_evaluations(code), trimestre smallint not null check (trimestre between 1 and 3),
  titre text not null, bareme numeric(5,2) not null default 20 check (bareme > 0), date_eval date not null,
  statut eval_statut not null default 'brouillon',
  auteur_id uuid references utilisateurs(id), soumis_le timestamptz, valide_par uuid references utilisateurs(id), valide_le timestamptz, motif_retour text,
  supprime_le timestamptz);
-- Distinction stricte : 0 (note) ≠ absent ≠ dispensé ≠ non saisi (absence de ligne)
create table if not exists notes (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  evaluation_id uuid not null references evaluations(id), inscription_id uuid not null references inscriptions(id),
  etat note_etat not null default 'note', valeur numeric(5,2) check (valeur >= 0),
  supprime_le timestamptz,
  unique (evaluation_id, inscription_id),
  check ((etat = 'note' and valeur is not null) or (etat <> 'note' and valeur is null)));
create table if not exists appreciations (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  inscription_id uuid not null references inscriptions(id), trimestre smallint not null check (trimestre between 1 and 4),
  texte text not null, auteur_id uuid references utilisateurs(id), proposee boolean not null default false,
  unique (inscription_id, trimestre));
create table if not exists bulletins (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  classe_id uuid not null references classes(id), trimestre smallint not null check (trimestre between 1 and 4),
  statut text not null default 'brouillon' check (statut in ('brouillon','valide')),
  snapshot jsonb, valide_par uuid references utilisateurs(id), valide_le timestamptz,
  historique jsonb not null default '[]',
  unique (classe_id, trimestre));
create table if not exists conseils_classe (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  classe_id uuid not null references classes(id), periode text not null check (periode in ('1','2','3','annuel')),
  date_conseil date, pv text, unique (classe_id, periode));
create table if not exists decisions_conseil (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  inscription_id uuid not null references inscriptions(id), periode text not null default 'annuel',
  decision text not null, motif text, statut decision_statut not null default 'propose',
  auteur_id uuid references utilisateurs(id), valide_par uuid references utilisateurs(id), valide_le timestamptz,
  historique jsonb not null default '[]');
create unique index if not exists ux_decision_active on decisions_conseil (inscription_id, periode) where statut <> 'annule';
create table if not exists historiques_promotion (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  decision_id uuid not null references decisions_conseil(id),
  inscription_origine uuid not null references inscriptions(id), inscription_cible uuid not null references inscriptions(id),
  auteur_id uuid references utilisateurs(id), date_op timestamptz not null default now(),
  statut text not null default 'effectuee' check (statut in ('effectuee','annulee')), motif_annulation text);

-- ---------- 7. Vie scolaire ----------
create table if not exists absences (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  inscription_id uuid not null references inscriptions(id), date_abs date not null,
  type text not null check (type in ('Absence','Retard')), duree text, justifiee boolean not null default false, motif text);
create table if not exists cahier_textes (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  classe_id uuid not null references classes(id), matiere_code text not null references matieres(code),
  date_seance date not null, contenu text not null, devoir text, auteur_id uuid references utilisateurs(id));
create table if not exists emplois_temps (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  classe_id uuid not null references classes(id), jour text not null, creneau text not null,
  matiere_code text references matieres(code), salle text, unique (classe_id, jour, creneau));

-- ---------- 8. Administration ----------
create table if not exists courriers (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  type text not null check (type in ('interne','externe')), sens text not null,
  objet text not null, destinataire text, contenu text, numero text,
  statut text not null default 'brouillon' check (statut in ('brouillon','valide','signe','transmis','accuse','archive')),
  date_courrier date not null default current_date, auteur_id uuid references utilisateurs(id),
  unique (etablissement_id, numero));
create table if not exists courrier_destinataires (
  courrier_id uuid not null references courriers(id), utilisateur_id uuid not null references utilisateurs(id),
  accuse_le timestamptz, primary key (courrier_id, utilisateur_id));
create table if not exists notifications (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid references etablissements(id),
  user_id uuid references utilisateurs(id), roles role_code[], titre text not null, message text,
  created_at timestamptz not null default now(), lu_par uuid[] not null default '{}');
create table if not exists archives (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  reference text not null, titre text not null, categorie text, date_doc date not null,
  duree_conservation_ans int not null check (duree_conservation_ans > 0), localisation text,
  acces text not null default 'interne' check (acces in ('interne','restreint')), fichier_path text,
  unique (etablissement_id, reference));
create table if not exists documents (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  titre text not null, fichier_path text not null, created_by uuid references utilisateurs(id), created_at timestamptz not null default now());

-- ---------- 8 bis. Rapports (manuels, assistés par IA, importés) ----------
create table if not exists rapports (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  annee_id uuid references annees_scolaires(id), titre text not null,
  type text not null check (type in ('resultats','effectifs','financier','vie','synthese','libre')),
  periode text, mode text not null default 'manuel' check (mode in ('manuel','ia','importe')),
  statut text not null default 'brouillon' check (statut in ('brouillon','valide')),
  sections jsonb not null default '[]',            -- [{titre, texte, tab:{heads,rows}}]
  auteur text, date_rapport date, created_by uuid references utilisateurs(id),
  valide_par uuid references utilisateurs(id), valide_le timestamptz, created_at timestamptz not null default now());
create index if not exists ix_rapports_etab on rapports(etablissement_id, annee_id);

-- ---------- 8 ter. Identité visuelle : logo, cachet (établissement) et signature (utilisateur) ----------
-- Les images sont stockées dans le bucket privé « sceaux » ; image_path en est le chemin.
create table if not exists sceaux (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  kind text not null check (kind in ('logo','cachet','signature')),
  user_id uuid references utilisateurs(id), image_path text not null, mis_a_jour_le timestamptz not null default now(),
  check ((kind = 'signature') = (user_id is not null)));
create unique index if not exists ux_sceaux_etab on sceaux(etablissement_id, kind) where user_id is null;
create unique index if not exists ux_sceaux_user on sceaux(user_id) where kind = 'signature';

-- ---------- 9. Finances ----------
create table if not exists frais_scolarite (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  annee_id uuid not null references annees_scolaires(id), niveau_id text not null references niveaux(id),
  libelle text not null, montant numeric(12,0) not null check (montant >= 0));
create table if not exists echeances (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  inscription_id uuid not null references inscriptions(id), libelle text not null,
  date_limite date not null, montant numeric(12,0) not null check (montant > 0));
create table if not exists caisses (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  libelle text not null, mode text not null, unique (etablissement_id, libelle));
create table if not exists compteurs (
  etablissement_id uuid not null references etablissements(id), nom text not null, annee text not null, valeur int not null default 0,
  primary key (etablissement_id, nom, annee));
create table if not exists paiements (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  annee_id uuid not null references annees_scolaires(id), inscription_id uuid not null references inscriptions(id),
  montant numeric(12,0) not null check (montant > 0), mode text not null, date_paiement date not null default current_date,
  reference text not null,                       -- clé d'idempotence générée côté client, une seule fois
  numero_recu text,
  caisse_id uuid references caisses(id), saisi_par uuid references utilisateurs(id), supprime_le timestamptz,
  unique (etablissement_id, reference));
create table if not exists recus (
  id uuid primary key default gen_random_uuid(), paiement_id uuid not null unique references paiements(id),
  etablissement_id uuid not null references etablissements(id), numero text not null, emis_le timestamptz not null default now(),
  unique (etablissement_id, numero));
create table if not exists recettes (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  annee_id uuid not null references annees_scolaires(id), date_op date not null, libelle text not null,
  montant numeric(12,0) not null check (montant > 0), mode text not null);
create table if not exists depenses (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  annee_id uuid not null references annees_scolaires(id), date_op date not null, libelle text not null, categorie text,
  montant numeric(12,0) not null check (montant > 0), mode text not null);

-- ---------- 10. Bibliothèque ----------
create table if not exists ouvrages (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  titre text not null, auteur text, categorie text);
create table if not exists exemplaires (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  ouvrage_id uuid not null references ouvrages(id), cote text not null, etat text not null default 'Bon',
  unique (etablissement_id, cote));
-- « retours » : colonne retour_date de l'emprunt (un seul enregistrement par prêt)
create table if not exists emprunts (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid not null references etablissements(id),
  exemplaire_id uuid not null references exemplaires(id), emprunteur text not null,
  date_emprunt date not null default current_date, retour_prevu date not null, retour_date date);
create unique index if not exists ux_emprunt_ouvert on emprunts (exemplaire_id) where retour_date is null;

-- ---------- 11. IA ----------
create table if not exists ia_configurations (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid references etablissements(id),
  actif boolean not null default false, assistants jsonb not null default '[]', quota_jour int not null default 50);
create table if not exists ia_usages (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid references etablissements(id),
  user_id uuid references utilisateurs(id), role role_code, assistant text not null,
  taille_demande int, contexte text, mode text, created_at timestamptz not null default now());
create table if not exists ia_ressources (id uuid primary key default gen_random_uuid(), etablissement_id uuid references etablissements(id), titre text not null, contenu text);
create table if not exists ia_analyses (
  id uuid primary key default gen_random_uuid(), etablissement_id uuid references etablissements(id),
  user_id uuid references utilisateurs(id), perimetre text, resume text, created_at timestamptz not null default now());

-- ---------- 12. Sécurité et synchronisation ----------
create table if not exists journal_activites (
  id bigint generated always as identity primary key, t timestamptz not null default now(),
  user_id uuid, role role_code, etablissement_id uuid, module text not null, action text not null,
  cible text, details jsonb, appareil text, prev_hash text, hash text);
create table if not exists synchronisations (            -- idempotence : une opération n'est appliquée qu'une fois
  op_id uuid primary key, user_id uuid, appareil text, table_name text not null, record_id uuid not null,
  base_version int, statut text not null, applique_le timestamptz not null default now());
create table if not exists conflits_sync (
  id uuid primary key default gen_random_uuid(), op_id uuid not null, table_name text not null, record_id uuid not null,
  version_client int, version_serveur int, payload_client jsonb, payload_serveur jsonb,
  resolu boolean not null default false, resolu_par uuid, resolu_le timestamptz, decision text);
create table if not exists sauvegardes (
  id uuid primary key default gen_random_uuid(), t timestamptz not null default now(), type text not null,
  emplacement text not null, taille_octets bigint, somme_sha256 text, restauration_testee_le timestamptz, resultat_test text);

-- Colonnes techniques communes (version optimiste, horodatage, auteur) sur toutes les tables métier
do $$
declare t text;
begin
  foreach t in array array['classes','eleves','inscriptions','affectations','coefficients','evaluations','notes','appreciations','bulletins','conseils_classe','decisions_conseil','historiques_promotion','absences','cahier_textes','emplois_temps','courriers','archives','rapports','sceaux','frais_scolarite','paiements','recettes','depenses','ouvrages','exemplaires','emprunts','etablissements','utilisateurs']
  loop
    execute format('alter table public.%I add column if not exists version int not null default 1', t);
    execute format('alter table public.%I add column if not exists updated_at timestamptz not null default now()', t);
    execute format('alter table public.%I add column if not exists updated_by uuid', t);
  end loop;
end $$;
create or replace function trg_version() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' then new.version := old.version + 1; end if;
  new.updated_at := now(); new.updated_by := auth.uid();
  return new;
end $$;

-- ---------- 13. Fonctions de périmètre et de permission (utilisées par la RLS) ----------
create or replace function pj_role() returns role_code language sql stable security definer set search_path = public as
$$ select role from utilisateurs where id = auth.uid() and actif $$;

create or replace function pj_etabs() returns setof uuid language sql stable security definer set search_path = public as
$$ select e.id from etablissements e join utilisateurs u on u.id = auth.uid() and u.actif
   where e.actif and (
        u.role in ('superadmin','deps')
     or (u.role = 'drenaet'   and e.drenaet_id = u.drenaet_id)
     or (u.role = 'fondateur' and exists (select 1 from fondateur_etablissements fe where fe.fondateur_id = u.fondateur_id and fe.etablissement_id = e.id))
     or (u.role not in ('superadmin','deps','drenaet','fondateur') and e.id = u.etablissement_id)) $$;

create or replace function pj_in_scope(p_etab uuid) returns boolean language sql stable security definer set search_path = public as
$$ select p_etab is not null and p_etab in (select pj_etabs()) $$;

-- Droit sur un module/une action pour un établissement : rôle + dérogations individuelles, toujours borné au périmètre
create or replace function pj_can(p_module text, p_action char, p_etab uuid) returns boolean language sql stable security definer set search_path = public as
$$ select pj_in_scope(p_etab)
   and not exists (select 1 from user_permissions up where up.user_id = auth.uid() and up.module = p_module and up.action = p_action and not up.granted and (up.etablissement_id is null or up.etablissement_id = p_etab))
   and ( exists (select 1 from role_permissions rp where rp.role = pj_role() and rp.module = p_module and rp.action = p_action)
      or exists (select 1 from user_permissions up where up.user_id = auth.uid() and up.module = p_module and up.action = p_action and up.granted and (up.etablissement_id is null or up.etablissement_id = p_etab))
      or (exists (select 1 from classes c where c.prof_principal_id = auth.uid() and c.etablissement_id = p_etab and c.supprime_le is null)
          and ((p_module = 'pp' and p_action in ('L','M')) or (p_module = 'bulletins' and p_action in ('L','X')) or (p_module = 'conseils' and p_action in ('L','C','M')))) ) $$;

-- Professeur principal d'une classe
create or replace function pj_est_pp(p_classe uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from classes c where c.id = p_classe and c.prof_principal_id = auth.uid()) $$;
-- Enseignant affecté à (classe, matière)
create or replace function pj_est_affecte(p_classe uuid, p_matiere text) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from affectations a where a.enseignant_id = auth.uid() and a.classe_id = p_classe and a.matiere_code = p_matiere and a.supprime_le is null) $$;
-- Accès aux bulletins : management + profils expressément habilités (paramètre de l'établissement)
create or replace function pj_acces_bulletin(p_etab uuid, p_classe uuid) returns boolean language sql stable security definer set search_path = public as
$$ select pj_in_scope(p_etab) and (
        pj_role() in ('directeur','fondateur')
     or (pj_role() = 'enseignant' and pj_est_pp(p_classe) and (select params->'bulletins_roles' ? 'professeur_principal' from etablissements where id = p_etab))
     or (pj_role()::text in ('secretariat','deps','drenaet') and (select params->'bulletins_roles' ? pj_role()::text from etablissements where id = p_etab))) $$;

-- ---------- 14. Row Level Security ----------
-- Tables rattachées à un établissement : (table, module de permission)
create table if not exists _rls_map (tbl text primary key, module text not null);
insert into _rls_map values
 ('classes','classes'),('eleves','eleves'),('responsables_legaux','eleves'),('inscriptions','eleves'),('affectations','enseignants'),('coefficients','params'),
 ('evaluations','notes'),('notes','notes'),('appreciations','pp'),('conseils_classe','conseils'),('decisions_conseil','conseils'),('historiques_promotion','conseils'),
 ('absences','vie'),('cahier_textes','vie'),('emplois_temps','vie'),('courriers','courriers'),('documents','archives'),
 ('frais_scolarite','finances'),('echeances','finances'),('caisses','finances'),('paiements','finances'),('recus','finances'),('recettes','finances'),('depenses','finances'),
 ('ouvrages','biblio'),('exemplaires','biblio'),('emprunts','biblio'),('rapports','rapports'),('sceaux','sceau')
on conflict do nothing;

do $$
declare r record; has_etab boolean;
begin
  for r in select tbl, module from _rls_map loop
    execute format('alter table public.%I enable row level security', r.tbl);
    execute format('alter table public.%I force row level security', r.tbl);
    -- tables sans colonne etablissement_id propre : responsables_legaux
    select exists (select 1 from information_schema.columns where table_schema='public' and table_name=r.tbl and column_name='etablissement_id') into has_etab;
    if has_etab then
      execute format('drop policy if exists p_sel on public.%I', r.tbl);
      execute format('drop policy if exists p_ins on public.%I', r.tbl);
      execute format('drop policy if exists p_upd on public.%I', r.tbl);
      execute format('create policy p_sel on public.%I for select to authenticated using (pj_can(%L, ''L'', etablissement_id))', r.tbl, r.module);
      execute format('create policy p_ins on public.%I for insert to authenticated with check (pj_can(%L, ''C'', etablissement_id))', r.tbl, r.module);
      execute format('create policy p_upd on public.%I for update to authenticated using (pj_can(%L, ''M'', etablissement_id)) with check (pj_can(%L, ''M'', etablissement_id))', r.tbl, r.module, r.module);
      -- aucune politique DELETE : suppression logique uniquement
    end if;
  end loop;
end $$;
-- responsables_legaux : via l'élève
alter table responsables_legaux enable row level security;
drop policy if exists p_sel on responsables_legaux; drop policy if exists p_ins on responsables_legaux; drop policy if exists p_upd on responsables_legaux;
create policy p_sel on responsables_legaux for select to authenticated using (exists (select 1 from eleves e where e.id = eleve_id and pj_can('eleves','L',e.etablissement_id) and pj_role() <> 'enseignant'));
create policy p_ins on responsables_legaux for insert to authenticated with check (exists (select 1 from eleves e where e.id = eleve_id and pj_can('eleves','C',e.etablissement_id)));
create policy p_upd on responsables_legaux for update to authenticated using (exists (select 1 from eleves e where e.id = eleve_id and pj_can('eleves','M',e.etablissement_id)));

-- Enseignants : leurs classes seulement ; saisie de notes limitée à (classe, matière) affectées
drop policy if exists p_sel on classes;
create policy p_sel on classes for select to authenticated using (pj_can('classes','L',etablissement_id) and (pj_role() <> 'enseignant' or prof_principal_id = auth.uid() or exists (select 1 from affectations a where a.classe_id = classes.id and a.enseignant_id = auth.uid())));
drop policy if exists p_sel on inscriptions;
create policy p_sel on inscriptions for select to authenticated using (pj_can('eleves','L',etablissement_id) and (pj_role() <> 'enseignant' or pj_est_pp(classe_id) or exists (select 1 from affectations a where a.classe_id = inscriptions.classe_id and a.enseignant_id = auth.uid())));
drop policy if exists p_ins on evaluations; drop policy if exists p_upd on evaluations;
create policy p_ins on evaluations for insert to authenticated with check (pj_can('notes','C',etablissement_id) and pj_est_affecte(classe_id, matiere_code));
create policy p_upd on evaluations for update to authenticated using (pj_can('notes','M',etablissement_id) and pj_est_affecte(classe_id, matiere_code) or pj_can('notes','V',etablissement_id)) with check (pj_can('notes','M',etablissement_id) or pj_can('notes','V',etablissement_id));
drop policy if exists p_ins on notes; drop policy if exists p_upd on notes;
create policy p_ins on notes for insert to authenticated with check (pj_can('notes','C',etablissement_id) and exists (select 1 from evaluations e where e.id = evaluation_id and pj_est_affecte(e.classe_id, e.matiere_code)));
create policy p_upd on notes for update to authenticated using (pj_can('notes','M',etablissement_id) and exists (select 1 from evaluations e where e.id = evaluation_id and pj_est_affecte(e.classe_id, e.matiere_code)));
-- Consolidation : le professeur principal lit les notes de sa classe (sans pouvoir les modifier)
drop policy if exists p_sel on notes;
create policy p_sel on notes for select to authenticated using (pj_can('notes','L',etablissement_id) and (pj_role() <> 'enseignant' or exists (select 1 from evaluations e where e.id = evaluation_id and (pj_est_affecte(e.classe_id, e.matiere_code) or pj_est_pp(e.classe_id)))));
drop policy if exists p_sel on evaluations;
create policy p_sel on evaluations for select to authenticated using (pj_can('notes','L',etablissement_id) and (pj_role() <> 'enseignant' or pj_est_affecte(classe_id, matiere_code) or pj_est_pp(classe_id)));
-- Finances : visibles uniquement des profils habilités (le module 'finances' n'existe que pour intendant/directeur/fondateur)

-- Bulletins : management + profils habilités
alter table bulletins enable row level security; alter table bulletins force row level security;
drop policy if exists p_sel on bulletins; drop policy if exists p_ins on bulletins; drop policy if exists p_upd on bulletins;
create policy p_sel on bulletins for select to authenticated using (pj_acces_bulletin(etablissement_id, classe_id));
create policy p_ins on bulletins for insert to authenticated with check (pj_can('bulletins','V',etablissement_id));
create policy p_upd on bulletins for update to authenticated using (pj_can('bulletins','V',etablissement_id));
-- Archives : dossiers « restreint » réservés à la direction et à l'archiviste
alter table archives enable row level security; alter table archives force row level security;
drop policy if exists p_sel on archives; drop policy if exists p_ins on archives; drop policy if exists p_upd on archives;
create policy p_sel on archives for select to authenticated using (pj_can('archives','L',etablissement_id) and (acces = 'interne' or pj_role() in ('directeur','archiviste')));
create policy p_ins on archives for insert to authenticated with check (pj_can('archives','C',etablissement_id));
create policy p_upd on archives for update to authenticated using (pj_can('archives','M',etablissement_id));
-- Notifications : destinataire seulement
alter table notifications enable row level security; alter table notifications force row level security;
drop policy if exists p_sel on notifications; drop policy if exists p_ins on notifications; drop policy if exists p_upd on notifications;
create policy p_sel on notifications for select to authenticated using (user_id = auth.uid() or (user_id is null and pj_role() = any (roles) and pj_in_scope(etablissement_id)));
create policy p_ins on notifications for insert to authenticated with check (pj_in_scope(etablissement_id));
create policy p_upd on notifications for update to authenticated using (user_id = auth.uid() or (user_id is null and pj_role() = any (roles) and pj_in_scope(etablissement_id)));
-- Organisation : lecture dans le périmètre ; écriture réservée au superadministrateur
alter table etablissements enable row level security; alter table etablissements force row level security;
drop policy if exists p_sel on etablissements; drop policy if exists p_wr on etablissements;
create policy p_sel on etablissements for select to authenticated using (id in (select pj_etabs()));
create policy p_wr on etablissements for all to authenticated using (pj_role() = 'superadmin') with check (pj_role() = 'superadmin');
do $$
declare t text;
begin
  foreach t in array array['regions','drenaet','fondateurs','fondateur_etablissements','annees_scolaires','niveaux','matieres','types_evaluations','role_permissions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists p_sel on public.%I', t);
    execute format('drop policy if exists p_wr on public.%I', t);
    execute format('create policy p_sel on public.%I for select to authenticated using (pj_role() is not null)', t);
    execute format('create policy p_wr on public.%I for all to authenticated using (pj_role() = ''superadmin'') with check (pj_role() = ''superadmin'')', t);
  end loop;
end $$;
-- Utilisateurs : son propre profil + les comptes des établissements du périmètre (pour les rôles autorisés)
alter table utilisateurs enable row level security; alter table utilisateurs force row level security;
drop policy if exists p_sel on utilisateurs; drop policy if exists p_ins on utilisateurs; drop policy if exists p_upd on utilisateurs;
create policy p_sel on utilisateurs for select to authenticated using (id = auth.uid() or pj_role() = 'superadmin' or (etablissement_id is not null and pj_can('users','L',etablissement_id)) or (etablissement_id is not null and pj_can('enseignants','L',etablissement_id)));
create policy p_ins on utilisateurs for insert to authenticated with check (pj_role() = 'superadmin' or (etablissement_id is not null and pj_can('users','C',etablissement_id) and role in ('secretariat','intendant','bibliothecaire','archiviste','enseignant')));
create policy p_upd on utilisateurs for update to authenticated using (pj_role() = 'superadmin' or (etablissement_id is not null and pj_can('users','M',etablissement_id) and role <> 'superadmin'));
-- Journal : lecture superadmin (tout) / direction (son établissement) ; aucune écriture directe
alter table journal_activites enable row level security; alter table journal_activites force row level security;
drop policy if exists p_sel on journal_activites;
create policy p_sel on journal_activites for select to authenticated using (pj_role() = 'superadmin' or (etablissement_id is not null and pj_can('audit','L',etablissement_id)));
revoke insert, update, delete on journal_activites from authenticated, anon;
-- Tables techniques : IA, synchronisation, sauvegardes, appareils, sessions
do $$
declare t text;
begin
  foreach t in array array['user_permissions','appareils','sessions_app','synchronisations','conflits_sync','sauvegardes','ia_configurations','ia_usages','ia_ressources','ia_analyses','compteurs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists p_adm on public.%I', t);
    execute format('create policy p_adm on public.%I for all to authenticated using (pj_role() = ''superadmin'') with check (pj_role() = ''superadmin'')', t);
  end loop;
end $$;
drop policy if exists p_own on appareils; create policy p_own on appareils for select to authenticated using (user_id = auth.uid());
drop policy if exists p_own on sessions_app; create policy p_own on sessions_app for select to authenticated using (user_id = auth.uid());
drop policy if exists p_own on ia_usages; create policy p_own on ia_usages for select to authenticated using (user_id = auth.uid());
drop policy if exists p_own_sync on synchronisations; create policy p_own_sync on synchronisations for select to authenticated using (user_id = auth.uid());
drop policy if exists p_perm on user_permissions; create policy p_perm on user_permissions for select to authenticated using (user_id = auth.uid());

-- ---------- 15. Journal d'audit chaîné ----------
create or replace function trg_journal_hash() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare v_prev text;
begin
  perform pg_advisory_xact_lock(727001);               -- sérialise l'écriture de la chaîne
  select hash into v_prev from journal_activites order by id desc limit 1;
  new.prev_hash := coalesce(v_prev, '0');
  new.hash := encode(digest(new.prev_hash || coalesce(new.user_id::text,'') || new.t::text || new.module || new.action || coalesce(new.cible,'') || coalesce(new.details::text,''), 'sha256'), 'hex');
  return new;
end $$;
drop trigger if exists journal_hash on journal_activites;
create trigger journal_hash before insert on journal_activites for each row execute function trg_journal_hash();

create or replace function trg_audit() returns trigger language plpgsql security definer set search_path = public as $$
declare v_row jsonb; v_etab uuid;
begin
  v_row := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_etab := coalesce((v_row->>'etablissement_id')::uuid, case when tg_table_name = 'etablissements' then (v_row->>'id')::uuid end);
  insert into journal_activites (user_id, role, etablissement_id, module, action, cible, details)
  values (auth.uid(), pj_role(), v_etab, tg_table_name, lower(tg_op), v_row->>'id',
          case when tg_op = 'UPDATE' then jsonb_build_object('avant', to_jsonb(old) - 'photo_path', 'apres', to_jsonb(new) - 'photo_path') else v_row end);
  return null;
end $$;
create or replace function trg_no_delete() returns trigger language plpgsql as $$
begin raise exception 'Suppression physique interdite sur % (suppression logique uniquement)', tg_table_name; end $$;

do $$
declare t text;
begin
  foreach t in array array['notes','evaluations','bulletins','decisions_conseil','historiques_promotion','paiements','recus','recettes','depenses','user_permissions','utilisateurs','etablissements','coefficients','inscriptions','eleves'] loop
    execute format('drop trigger if exists audit_%1$s on public.%1$I', t);
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I for each row execute function trg_audit()', t);
    execute format('drop trigger if exists nodel_%1$s on public.%1$I', t);
    execute format('create trigger nodel_%1$s before delete on public.%1$I for each row execute function trg_no_delete()', t);
  end loop;
  foreach t in array array['classes','eleves','inscriptions','affectations','coefficients','evaluations','notes','appreciations','bulletins','conseils_classe','decisions_conseil','historiques_promotion','absences','cahier_textes','emplois_temps','courriers','archives','rapports','sceaux','frais_scolarite','paiements','recettes','depenses','ouvrages','exemplaires','emprunts','etablissements','utilisateurs'] loop
    execute format('drop trigger if exists ver_%1$s on public.%1$I', t);
    execute format('create trigger ver_%1$s before insert or update on public.%1$I for each row execute function trg_version()', t);
  end loop;
end $$;

-- ---------- 16. Règles de workflow ----------
-- Notes : saisie dans la barème, uniquement tant que l'évaluation est en brouillon
create or replace function trg_notes_regles() returns trigger language plpgsql as $$
declare e evaluations%rowtype;
begin
  select * into e from evaluations where id = new.evaluation_id;
  if e.statut <> 'brouillon' then raise exception 'Évaluation % verrouillée (statut %)', e.titre, e.statut; end if;
  if new.etat = 'note' and new.valeur > e.bareme then raise exception 'Note % supérieure au barème %', new.valeur, e.bareme; end if;
  return new;
end $$;
drop trigger if exists notes_regles on notes;
create trigger notes_regles before insert or update on notes for each row execute function trg_notes_regles();

-- Évaluations : transitions autorisées brouillon → soumis → valide ; retour au brouillon motivé
create or replace function trg_eval_transition() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.statut is distinct from old.statut then
    if old.statut = 'brouillon' and new.statut = 'soumis' then new.soumis_le := now();
    elsif old.statut = 'soumis' and new.statut = 'valide' then
      if not pj_can('notes','V',new.etablissement_id) then raise exception 'Validation réservée à la direction'; end if;
      new.valide_par := auth.uid(); new.valide_le := now();
    elsif new.statut = 'brouillon' and old.statut in ('soumis','valide') then
      if not pj_can('notes','V',new.etablissement_id) then raise exception 'Retour en brouillon réservé à la direction'; end if;
      if coalesce(new.motif_retour,'') = '' then raise exception 'Motif obligatoire'; end if;
      if exists (select 1 from bulletins b where b.classe_id = new.classe_id and b.trimestre = new.trimestre and b.statut = 'valide') then raise exception 'Un bulletin validé existe : le rouvrir d''abord'; end if;
    else raise exception 'Transition % → % interdite', old.statut, new.statut; end if;
  elsif tg_op = 'UPDATE' and old.statut <> 'brouillon' and (new.bareme is distinct from old.bareme or new.matiere_code is distinct from old.matiere_code or new.classe_id is distinct from old.classe_id) then
    raise exception 'Évaluation verrouillée';
  end if;
  return new;
end $$;
drop trigger if exists eval_transition on evaluations;
create trigger eval_transition before update on evaluations for each row execute function trg_eval_transition();

-- Bulletins validés : figés ; seule la réouverture motivée (retour au brouillon) est possible
create or replace function trg_bulletin_gel() returns trigger language plpgsql as $$
begin
  if old.statut = 'valide' then
    if new.statut = 'brouillon' then
      new.historique := old.historique || jsonb_build_object('t', now(), 'par', auth.uid(), 'ancienne_validation', old.valide_le);
    elsif new.snapshot is distinct from old.snapshot then raise exception 'Bulletin validé : résultats figés'; end if;
  elsif new.statut = 'valide' then
    if exists (select 1 from evaluations e where e.classe_id = new.classe_id and e.trimestre = new.trimestre and e.statut <> 'valide' and e.supprime_le is null) then raise exception 'Évaluations non validées pour cette période'; end if;
    new.valide_par := auth.uid(); new.valide_le := now();
  end if;
  return new;
end $$;
drop trigger if exists bulletin_gel on bulletins;
create trigger bulletin_gel before update on bulletins for each row execute function trg_bulletin_gel();

-- Décisions : une décision validée ne se modifie que via correction historisée par la direction
create or replace function trg_decision_regles() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.statut = 'valide' and new.decision is distinct from old.decision then
    if not pj_can('conseils','V',new.etablissement_id) then raise exception 'Correction réservée à la direction'; end if;
    if exists (select 1 from historiques_promotion h where h.decision_id = old.id and h.statut = 'effectuee') then raise exception 'Une promotion a été effectuée : l''annuler d''abord'; end if;
    new.historique := old.historique || jsonb_build_object('t', now(), 'par', auth.uid(), 'de', old.decision, 'a', new.decision, 'motif', new.motif);
  end if;
  if new.statut = 'valide' and (tg_op = 'INSERT' or old.statut <> 'valide') then
    if not pj_can('conseils','V',new.etablissement_id) then raise exception 'Validation réservée à la direction'; end if;
    new.valide_par := auth.uid(); new.valide_le := now();
  end if;
  return new;
end $$;
drop trigger if exists decision_regles on decisions_conseil;
create trigger decision_regles before insert or update on decisions_conseil for each row execute function trg_decision_regles();

-- Paiements : numéro de reçu séquentiel par établissement/année, idempotence par (etablissement, reference)
create or replace function trg_paiement_recu() returns trigger language plpgsql as $$
declare v_annee text; v_n int; v_solde numeric;
begin
  select a.libelle into v_annee from annees_scolaires a where a.id = new.annee_id;
  insert into compteurs (etablissement_id, nom, annee, valeur) values (new.etablissement_id, 'recu', v_annee, 1)
    on conflict (etablissement_id, nom, annee) do update set valeur = compteurs.valeur + 1 returning valeur into v_n;
  new.numero_recu := 'R' || lpad(v_n::text, 5, '0');
  return new;
end $$;
drop trigger if exists paiement_recu on paiements;
create trigger paiement_recu before insert on paiements for each row execute function trg_paiement_recu();

-- ---------- 17. Fonctions de calcul (miroir du moteur de l'application) ----------
create or replace function moyenne_matiere(p_insc uuid, p_matiere text, p_trim smallint, p_valides_seulement boolean default true)
returns numeric language sql stable as $$
  select round(sum((n.valeur / e.bareme * 20) * coalesce((et.params->'poids'->>e.type)::numeric, te.poids, 1))
               / nullif(sum(coalesce((et.params->'poids'->>e.type)::numeric, te.poids, 1)), 0), 2)
  from notes n
  join evaluations e on e.id = n.evaluation_id
  join etablissements et on et.id = e.etablissement_id
  left join types_evaluations te on te.code = e.type
  where n.inscription_id = p_insc and e.matiere_code = p_matiere and e.trimestre = p_trim
    and n.etat = 'note' and n.valeur is not null and n.supprime_le is null and e.supprime_le is null
    and (not p_valides_seulement or e.statut = 'valide') $$;

-- Moyenne générale = Σ(moy × coef) / Σ(coef des matières prises en compte, c.-à-d. ayant une moyenne)
create or replace function moyenne_generale(p_insc uuid, p_trim smallint, p_valides_seulement boolean default true)
returns numeric language sql stable as $$
  with c as (select cl.etablissement_id, cl.annee_id, cl.niveau_id from inscriptions i join classes cl on cl.id = i.classe_id where i.id = p_insc),
       m as (select co.coef, moyenne_matiere(p_insc, co.matiere_code, p_trim, p_valides_seulement) as moy
             from coefficients co join c on co.etablissement_id = c.etablissement_id and co.annee_id = c.annee_id and co.niveau_id = c.niveau_id
             where co.coef > 0)
  select round(sum(moy * coef) / nullif(sum(coef) filter (where moy is not null), 0), 2) from m $$;

-- Rang avec ex æquo (rang de compétition)
create or replace function rang_classe(p_insc uuid, p_trim smallint) returns int language sql stable as $$
  with cl as (select classe_id from inscriptions where id = p_insc),
       moy as (select i.id, moyenne_generale(i.id, p_trim) as mg from inscriptions i, cl where i.classe_id = cl.classe_id and i.statut in ('inscrit','reintegre'))
  select 1 + count(*)::int from moy where mg > (select mg from moy where id = p_insc) $$;

-- ---------- 18. Promotion automatique (après validation officielle des décisions) ----------
create or replace function promouvoir_classe(p_classe uuid, p_annee_cible uuid) returns int
language plpgsql as $$
declare v_cl classes%rowtype; r record; v_niv text; v_new uuid; v_ni uuid; n int := 0; v_nom text;
begin
  select * into v_cl from classes where id = p_classe;
  if not pj_can('conseils','V',v_cl.etablissement_id) then raise exception 'Promotion réservée à la direction'; end if;
  for r in
    select d.id as decision_id, d.decision, i.id as insc_id, i.eleve_id
    from decisions_conseil d join inscriptions i on i.id = d.inscription_id
    where i.classe_id = p_classe and d.periode = 'annuel' and d.statut = 'valide' and d.decision in ('Admis','Redoublant')
      and not exists (select 1 from historiques_promotion h where h.decision_id = d.id and h.statut = 'effectuee')
  loop
    v_niv := case when r.decision = 'Admis' then (select suivant from niveaux where id = v_cl.niveau_id) else v_cl.niveau_id end;
    continue when v_niv is null;                                       -- fin de cycle (Terminale)
    continue when not exists (select 1 from etablissements e join niveaux nv on nv.id = v_niv where e.id = v_cl.etablissement_id and nv.cycle = any (e.cycles));
    insert into coefficients (etablissement_id, annee_id, niveau_id, matiere_code, coef)
      select c.etablissement_id, p_annee_cible, c.niveau_id, c.matiere_code, c.coef from coefficients c
      where c.etablissement_id = v_cl.etablissement_id and c.annee_id = v_cl.annee_id and c.niveau_id = v_niv
      on conflict do nothing;
    select c.id into v_new from classes c
      where c.etablissement_id = v_cl.etablissement_id and c.annee_id = p_annee_cible and c.niveau_id = v_niv
        and (select count(*) from inscriptions x where x.classe_id = c.id and x.statut in ('inscrit','reintegre')) < c.capacite
      order by c.nom limit 1;
    if v_new is null then
      select nom || ' ' || chr(65 + (select count(*)::int from classes c where c.etablissement_id = v_cl.etablissement_id and c.annee_id = p_annee_cible and c.niveau_id = v_niv)) into v_nom from niveaux where id = v_niv;
      insert into classes (etablissement_id, annee_id, niveau_id, nom, capacite) values (v_cl.etablissement_id, p_annee_cible, v_niv, v_nom, v_cl.capacite) returning id into v_new;
    end if;
    insert into inscriptions (etablissement_id, annee_id, eleve_id, classe_id, statut, source)
      values (v_cl.etablissement_id, p_annee_cible, r.eleve_id, v_new, 'inscrit', 'promotion') returning id into v_ni;
    insert into historiques_promotion (etablissement_id, decision_id, inscription_origine, inscription_cible, auteur_id)
      values (v_cl.etablissement_id, r.decision_id, r.insc_id, v_ni, auth.uid());
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- 19. Synchronisation hors ligne : application d'une opération avec contrôle de version ----------
-- Appel type (depuis l'API) : select apply_sync_op(op_id, 'notes', id, base_version, payload, 'APP-1234');
create or replace function apply_sync_op(p_op_id uuid, p_table text, p_id uuid, p_base_version int, p_payload jsonb, p_appareil text default null)
returns jsonb language plpgsql as $$
declare v_cur jsonb; v_set text; v_ver int;
begin
  if p_table <> all (array['notes','evaluations','appreciations','decisions_conseil','paiements','absences','cahier_textes','emprunts','courriers']) then
    raise exception 'Table % non synchronisable', p_table; end if;
  if exists (select 1 from synchronisations where op_id = p_op_id) then
    return jsonb_build_object('statut','synchronise','idempotent',true); end if;
  execute format('select to_jsonb(t) from public.%I t where t.id = $1', p_table) into v_cur using p_id;
  if v_cur is null then
    execute format('insert into public.%I select * from jsonb_populate_record(null::public.%I, $1)', p_table, p_table) using (p_payload || jsonb_build_object('id', p_id));
    insert into synchronisations (op_id, user_id, appareil, table_name, record_id, base_version, statut) values (p_op_id, auth.uid(), p_appareil, p_table, p_id, p_base_version, 'synchronise');
    return jsonb_build_object('statut','synchronise','version',1);
  end if;
  v_ver := (v_cur->>'version')::int;
  if v_ver is distinct from p_base_version then            -- aucun écrasement silencieux
    insert into conflits_sync (op_id, table_name, record_id, version_client, version_serveur, payload_client, payload_serveur) values (p_op_id, p_table, p_id, p_base_version, v_ver, p_payload, v_cur);
    insert into synchronisations (op_id, user_id, appareil, table_name, record_id, base_version, statut) values (p_op_id, auth.uid(), p_appareil, p_table, p_id, p_base_version, 'conflit');
    return jsonb_build_object('statut','conflit','version_serveur',v_ver);
  end if;
  select string_agg(format('%I = r.%I', k, k), ', ') into v_set from jsonb_object_keys(p_payload) k where k not in ('id','version','created_at','updated_at','updated_by');
  execute format('update public.%I t set %s from jsonb_populate_record(null::public.%I, $1) r where t.id = $2', p_table, v_set, p_table) using p_payload, p_id;
  insert into synchronisations (op_id, user_id, appareil, table_name, record_id, base_version, statut) values (p_op_id, auth.uid(), p_appareil, p_table, p_id, p_base_version, 'synchronise');
  return jsonb_build_object('statut','synchronise','version', v_ver + 1);
end $$;

-- ---------- 20. Référentiels initiaux ----------
insert into niveaux (id, nom, cycle, ordre, suivant) values ('Tle','Terminale',2,7,null) on conflict do nothing;
insert into niveaux (id, nom, cycle, ordre, suivant) values ('1ere','Première',2,6,'Tle') on conflict do nothing;
insert into niveaux (id, nom, cycle, ordre, suivant) values ('2nde','Seconde',2,5,'1ere') on conflict do nothing;
insert into niveaux (id, nom, cycle, ordre, suivant) values ('3e','3ème',1,4,'2nde') on conflict do nothing;
insert into niveaux (id, nom, cycle, ordre, suivant) values ('4e','4ème',1,3,'3e') on conflict do nothing;
insert into niveaux (id, nom, cycle, ordre, suivant) values ('5e','5ème',1,2,'4e') on conflict do nothing;
insert into niveaux (id, nom, cycle, ordre, suivant) values ('6e','6ème',1,1,'5e') on conflict do nothing;
insert into matieres (code, nom) values ('MATH','Mathématiques'),('PC','Physique-Chimie'),('FR','Français'),('EPS','EPS'),('ARTS','Arts plastiques'),('SVT','SVT'),('MUS','Musique'),('ANG','Anglais'),('EDHC','EDHC'),('ESP','Espagnol'),('ALL','Allemand'),('COND','Conduite') on conflict do nothing;
insert into types_evaluations (code, poids) values ('Interrogation',1),('Devoir',1),('Composition',2) on conflict do nothing;
-- ---------- 21. Matrice des permissions (générée depuis l'application) ----------
insert into role_permissions (role, module, action) values
('superadmin','dashboard','L'),
('superadmin','orga','L'),
('superadmin','orga','C'),
('superadmin','orga','M'),
('superadmin','orga','A'),
('superadmin','users','L'),
('superadmin','users','C'),
('superadmin','users','M'),
('superadmin','users','A'),
('superadmin','params','L'),
('superadmin','params','C'),
('superadmin','params','M'),
('superadmin','params','A'),
('superadmin','classes','L'),
('superadmin','eleves','L'),
('superadmin','enseignants','L'),
('superadmin','notes','L'),
('superadmin','bulletins','L'),
('superadmin','conseils','L'),
('superadmin','stats','L'),
('superadmin','stats','X'),
('superadmin','ia','L'),
('superadmin','sync','L'),
('superadmin','sync','A'),
('superadmin','audit','L'),
('superadmin','audit','X'),
('superadmin','backup','L'),
('superadmin','backup','X'),
('superadmin','backup','A'),
('superadmin','analyse','L'),
('superadmin','courriers','L'),
('deps','dashboard','L'),
('deps','orga','L'),
('deps','orga','X'),
('deps','params','L'),
('deps','classes','L'),
('deps','eleves','L'),
('deps','enseignants','L'),
('deps','notes','L'),
('deps','bulletins','L'),
('deps','conseils','L'),
('deps','stats','L'),
('deps','stats','X'),
('deps','ia','L'),
('deps','sync','L'),
('deps','analyse','L'),
('drenaet','dashboard','L'),
('drenaet','orga','L'),
('drenaet','orga','X'),
('drenaet','params','L'),
('drenaet','classes','L'),
('drenaet','eleves','L'),
('drenaet','enseignants','L'),
('drenaet','notes','L'),
('drenaet','bulletins','L'),
('drenaet','conseils','L'),
('drenaet','stats','L'),
('drenaet','stats','X'),
('drenaet','courriers','L'),
('drenaet','ia','L'),
('drenaet','sync','L'),
('drenaet','analyse','L'),
('fondateur','dashboard','L'),
('fondateur','orga','L'),
('fondateur','users','L'),
('fondateur','params','L'),
('fondateur','classes','L'),
('fondateur','eleves','L'),
('fondateur','enseignants','L'),
('fondateur','notes','L'),
('fondateur','pp','L'),
('fondateur','bulletins','L'),
('fondateur','bulletins','X'),
('fondateur','conseils','L'),
('fondateur','finances','L'),
('fondateur','finances','X'),
('fondateur','courriers','L'),
('fondateur','vie','L'),
('fondateur','stats','L'),
('fondateur','stats','X'),
('fondateur','ia','L'),
('fondateur','sync','L'),
('fondateur','analyse','L'),
('directeur','dashboard','L'),
('directeur','orga','L'),
('directeur','users','L'),
('directeur','users','C'),
('directeur','users','M'),
('directeur','params','L'),
('directeur','params','C'),
('directeur','params','M'),
('directeur','params','A'),
('directeur','classes','L'),
('directeur','classes','C'),
('directeur','classes','M'),
('directeur','classes','X'),
('directeur','eleves','L'),
('directeur','eleves','C'),
('directeur','eleves','M'),
('directeur','eleves','X'),
('directeur','enseignants','L'),
('directeur','enseignants','C'),
('directeur','enseignants','M'),
('directeur','notes','L'),
('directeur','notes','V'),
('directeur','notes','X'),
('directeur','pp','L'),
('directeur','pp','M'),
('directeur','pp','V'),
('directeur','bulletins','L'),
('directeur','bulletins','V'),
('directeur','bulletins','X'),
('directeur','conseils','L'),
('directeur','conseils','C'),
('directeur','conseils','M'),
('directeur','conseils','V'),
('directeur','finances','L'),
('directeur','finances','X'),
('directeur','biblio','L'),
('directeur','archives','L'),
('directeur','archives','X'),
('directeur','courriers','L'),
('directeur','courriers','C'),
('directeur','courriers','M'),
('directeur','courriers','V'),
('directeur','courriers','X'),
('directeur','vie','L'),
('directeur','vie','C'),
('directeur','vie','M'),
('directeur','vie','X'),
('directeur','stats','L'),
('directeur','stats','X'),
('directeur','ia','L'),
('directeur','sync','L'),
('directeur','sync','A'),
('directeur','audit','L'),
('directeur','backup','L'),
('directeur','backup','X'),
('directeur','analyse','L'),
('secretariat','dashboard','L'),
('secretariat','classes','L'),
('secretariat','eleves','L'),
('secretariat','eleves','C'),
('secretariat','eleves','M'),
('secretariat','eleves','X'),
('secretariat','enseignants','L'),
('secretariat','courriers','L'),
('secretariat','courriers','C'),
('secretariat','courriers','M'),
('secretariat','courriers','V'),
('secretariat','courriers','X'),
('secretariat','archives','L'),
('secretariat','archives','C'),
('secretariat','vie','L'),
('secretariat','vie','C'),
('secretariat','ia','L'),
('secretariat','sync','L'),
('intendant','dashboard','L'),
('intendant','eleves','L'),
('intendant','finances','L'),
('intendant','finances','C'),
('intendant','finances','M'),
('intendant','finances','X'),
('intendant','ia','L'),
('intendant','sync','L'),
('bibliothecaire','dashboard','L'),
('bibliothecaire','eleves','L'),
('bibliothecaire','biblio','L'),
('bibliothecaire','biblio','C'),
('bibliothecaire','biblio','M'),
('bibliothecaire','biblio','X'),
('bibliothecaire','ia','L'),
('bibliothecaire','sync','L'),
('archiviste','dashboard','L'),
('archiviste','archives','L'),
('archiviste','archives','C'),
('archiviste','archives','M'),
('archiviste','archives','X'),
('archiviste','ia','L'),
('archiviste','sync','L'),
('enseignant','dashboard','L'),
('enseignant','classes','L'),
('enseignant','eleves','L'),
('enseignant','notes','L'),
('enseignant','notes','C'),
('enseignant','notes','M'),
('enseignant','vie','L'),
('enseignant','vie','C'),
('enseignant','ia','L'),
('enseignant','sync','L'),
('superadmin','rapports','L'),
('superadmin','rapports','C'),
('superadmin','rapports','M'),
('superadmin','rapports','X'),
('superadmin','sceau','L'),
('superadmin','sceau','C'),
('superadmin','sceau','M'),
('superadmin','sceau','A'),
('deps','rapports','L'),
('deps','rapports','C'),
('deps','rapports','M'),
('deps','rapports','X'),
('deps','sceau','L'),
('deps','sceau','C'),
('deps','sceau','M'),
('drenaet','rapports','L'),
('drenaet','rapports','C'),
('drenaet','rapports','M'),
('drenaet','rapports','X'),
('drenaet','sceau','L'),
('drenaet','sceau','C'),
('drenaet','sceau','M'),
('fondateur','rapports','L'),
('fondateur','rapports','C'),
('fondateur','rapports','M'),
('fondateur','rapports','X'),
('fondateur','sceau','L'),
('fondateur','sceau','C'),
('fondateur','sceau','M'),
('fondateur','sceau','A'),
('directeur','rapports','L'),
('directeur','rapports','C'),
('directeur','rapports','M'),
('directeur','rapports','V'),
('directeur','rapports','X'),
('directeur','sceau','L'),
('directeur','sceau','C'),
('directeur','sceau','M'),
('directeur','sceau','A'),
('secretariat','rapports','L'),
('secretariat','rapports','C'),
('secretariat','rapports','M'),
('secretariat','rapports','X'),
('secretariat','sceau','L'),
('secretariat','sceau','C'),
('secretariat','sceau','M'),
('intendant','rapports','L'),
('intendant','rapports','C'),
('intendant','rapports','M'),
('intendant','rapports','X'),
('intendant','sceau','L'),
('intendant','sceau','C'),
('intendant','sceau','M'),
('bibliothecaire','rapports','L'),
('bibliothecaire','rapports','C'),
('bibliothecaire','rapports','M'),
('bibliothecaire','sceau','L'),
('bibliothecaire','sceau','C'),
('bibliothecaire','sceau','M'),
('archiviste','rapports','L'),
('archiviste','rapports','C'),
('archiviste','rapports','M'),
('archiviste','sceau','L'),
('archiviste','sceau','C'),
('archiviste','sceau','M'),
('enseignant','rapports','L'),
('enseignant','rapports','C'),
('enseignant','rapports','M'),
('enseignant','rapports','X'),
('enseignant','sceau','L'),
('enseignant','sceau','C'),
('enseignant','sceau','M')
on conflict do nothing;
