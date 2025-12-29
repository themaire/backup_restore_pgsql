#!/bin/bash

# =============================================================================
# Script de backup PostgreSQL - Base lizmap_cenca_maps
# =============================================================================

# Chemin du script (pour trouver le README et .env)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Fonction d'affichage de l'aide
# -----------------------------------------------------------------------------
function show_help() {
    local readme_file="${SCRIPT_DIR}/README.md"
    
    echo ""
    echo "❌ ERREUR : $1"
    echo ""
    
    if [ -f "$readme_file" ]; then
        echo "📖 Documentation disponible :"
        echo "=============================================="
        cat "$readme_file"
        echo "=============================================="
    else
        echo "Usage: $0 <mode>"
        echo ""
        echo "Modes disponibles :"
        echo "   often        - Données métier importantes (quotidien)"
        echo "   occasionally - Données secondaires (hebdomadaire)"
        echo "   tous         - Tous les schémas (mensuel)"
    fi
    
    exit 1
}

# Vérifier si le premier paramètre est fourni
if [ -z "$1" ]; then
    show_help "Aucun paramètre fourni"
fi

# -----------------------------------------------------------------------------
# Chargement des credentials depuis .env
# -----------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    # Charger les variables d'environnement depuis .env
    set -a  # Exporter automatiquement les variables
    source "$ENV_FILE"
    set +a
else
    echo "⚠️  ATTENTION : Fichier .env introuvable !"
    echo "   Copier .env.example vers .env et configurer vos credentials :"
    echo "   cp ${SCRIPT_DIR}/.env.example ${SCRIPT_DIR}/.env"
    echo "   nano ${SCRIPT_DIR}/.env"
    exit 1
fi

# Vérifier que les variables essentielles sont définies
if [ -z "$PGHOST" ] || [ -z "$PGDATABASE" ] || [ -z "$PGUSER" ] || [ -z "$PGPASSWORD" ]; then
    echo "❌ ERREUR : Variables PostgreSQL manquantes dans .env"
    echo "   Vérifiez que PGHOST, PGDATABASE, PGUSER et PGPASSWORD sont définis."
    exit 1
fi

# Exporter les variables pour pg_dump
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

# -----------------------------------------------------------------------------
# Configuration des chemins
# -----------------------------------------------------------------------------
date_jour=$(date +"%Y%m%d")
date_heure=$(date +"%Y-%m-%d %H:%M:%S")

# Répertoire de backup (chargé depuis .env)
bkpdir_local="${BACKUP_DIR}"
workdir_local="${bkpdir_local}/${date_jour}"

# Répertoire de logs
log_dir="/var/log/backup_bdd"
log_file="${log_dir}/backup_bdd.log"

# Compteurs pour le résumé
success_count=0
error_count=0

# Configuration de la rétention (chargée depuis .env, avec valeurs par défaut)
RETENTION_DAYS_FULL=${RETENTION_DAYS_FULL:-7}
RETENTION_DAYS_WEEKLY=${RETENTION_DAYS_WEEKLY:-30}
RETENTION_DAYS_MONTHLY=${RETENTION_DAYS_MONTHLY:-90}
RETENTION_DAYS_YEARLY=${RETENTION_DAYS_YEARLY:-365}

# -----------------------------------------------------------------------------
# Fonction de logging
# -----------------------------------------------------------------------------
function init_log() {
    # Créer le répertoire de log s'il n'existe pas
    if [ ! -d "$log_dir" ]; then
        sudo mkdir -p "$log_dir"
        sudo chmod 755 "$log_dir"
        sudo chown "$USER:$USER" "$log_dir"
        echo "[$date_heure] Répertoire de log créé : $log_dir"
    fi
    
    # Créer le fichier de log s'il n'existe pas
    if [ ! -f "$log_file" ]; then
        sudo touch "$log_file"
        sudo chmod 644 "$log_file"
        sudo chown "$USER:$USER" "$log_file"
        echo "[$date_heure] Fichier de log créé : $log_file"
    fi
}

function log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$log_file"
}

# -----------------------------------------------------------------------------
# Création du répertoire de travail
# -----------------------------------------------------------------------------
function init_workdirs() {
    
    mkdir -p "$workdir_local"
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Impossible de créer le répertoire local : $workdir_local"
        exit 1
    fi
    
    log_message "INFO" "Répertoire de backup créé : $workdir_local"
}

# -----------------------------------------------------------------------------
# Vérification de la connexion à la base de données
# -----------------------------------------------------------------------------
function check_db_connection() {
    log_message "INFO" "Vérification de la connexion à la base de données..."
    if ! psql -c "SELECT 1" > /dev/null 2>&1; then
        log_message "ERROR" "Impossible de se connecter à la base de données $PGDATABASE sur $PGHOST"
        exit 1
    fi
    log_message "INFO" "Connexion à la base de données réussie"
}

# -----------------------------------------------------------------------------
# Chargement des listes de schémas depuis .env
# -----------------------------------------------------------------------------
# Convertir les chaînes en tableaux bash
read -ra tous <<< "$SCHEMAS_TOUS"
read -ra often <<< "$SCHEMAS_OFTEN"
read -ra occasionally <<< "$SCHEMAS_OCCASIONALLY"

# Vérifier que les listes sont définies
if [ ${#tous[@]} -eq 0 ] || [ ${#often[@]} -eq 0 ] || [ ${#occasionally[@]} -eq 0 ]; then
    echo "⚠️  ATTENTION : Listes de schémas non définies dans .env"
    echo "   Vérifiez que SCHEMAS_TOUS, SCHEMAS_OFTEN et SCHEMAS_OCCASIONALLY sont définis."
    exit 1
fi


function backup() {
    # Déclarer le tableau comme argument
    liste=("$@")
    log_message "INFO" "Début du backup - Schemas : ${liste[*]}"
    
    for schema in "${liste[@]}"; do
        local backup_file="sch_${schema}.sql"
        local backup_file_gz="${backup_file}.gz"
        
        log_message "INFO" "Backup du schema '$schema' en cours..."
        
        # Effectuer le dump et compresser directement avec gzip
        if pg_dump --schema "$schema" --inserts 2>/dev/null | gzip > "${workdir_local}/${backup_file_gz}"; then
            # Vérifier que le fichier n'est pas vide
            if [ -s "${workdir_local}/${backup_file_gz}" ]; then
                log_message "SUCCESS" "Schema '$schema' sauvegardé avec succès : ${backup_file_gz}"
                
                ((success_count++))
            else
                log_message "ERROR" "Schema '$schema' - Fichier de backup vide ou inexistant"
                rm -f "${workdir_local}/${backup_file_gz}"
                ((error_count++))
            fi
        else
            log_message "ERROR" "Échec du backup du schema '$schema'"
            ((error_count++))
        fi
    done
}

# =============================================================================
# Initialisation et exécution principale
# =============================================================================
init_log
log_message "INFO" "========================================"
log_message "INFO" "Démarrage du script de backup"
log_message "INFO" "Paramètre choisi : $1"
log_message "INFO" "========================================"

init_workdirs
check_db_connection

# Tester la valeur du premier paramètre
case $1 in
  "often")
    backup "${often[@]}"
    ;;
  "occasionally")
    backup "${occasionally[@]}"
    ;;
  "tous")
    backup "${tous[@]}"
    ;;
  *)
    show_help "Option invalide '$1'"
    ;;
esac

# -----------------------------------------------------------------------------
# Résumé final
# -----------------------------------------------------------------------------
log_message "INFO" "========================================"
log_message "INFO" "Backup terminé"
log_message "INFO" "Schemas sauvegardés avec succès : $success_count"
log_message "INFO" "Schemas en erreur : $error_count"
log_message "INFO" "Fichiers disponibles dans :"
log_message "INFO" "  - Local    : $workdir_local"
log_message "INFO" "========================================"

if [ $error_count -gt 0 ]; then
    exit 1
fi

# -----------------------------------------------------------------------------
# Rotation des backups
# -----------------------------------------------------------------------------
function cleanup_old_backups() {
    log_message "INFO" "========================================"
    log_message "INFO" "Début du nettoyage des anciens backups"
    log_message "INFO" "========================================"
    
    local deleted_count=0
    local kept_count=0
    local today=$(date +%s)
    
    # Parcourir tous les dossiers de backup (format YYYYMMDD)
    for backup_dir in "$bkpdir_local"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
        # Vérifier que c'est bien un dossier
        [ -d "$backup_dir" ] || continue
        
        # Extraire la date du nom du dossier
        local dir_name=$(basename "$backup_dir")
        local dir_date=$(date -d "${dir_name:0:4}-${dir_name:4:2}-${dir_name:6:2}" +%s 2>/dev/null)
        
        # Si la date n'est pas valide, passer
        [ -z "$dir_date" ] && continue
        
        # Calculer l'âge en jours
        local age_days=$(( (today - dir_date) / 86400 ))
        
        # Extraire le jour du mois et le jour de la semaine
        local day_of_month=$(date -d "${dir_name:0:4}-${dir_name:4:2}-${dir_name:6:2}" +%d)
        local day_of_week=$(date -d "${dir_name:0:4}-${dir_name:4:2}-${dir_name:6:2}" +%u)  # 1=lundi, 7=dimanche
        
        local should_delete=false
        local reason=""
        
        if [ $age_days -le $RETENTION_DAYS_FULL ]; then
            # Moins de 7 jours : tout garder
            reason="récent (<${RETENTION_DAYS_FULL}j)"
        elif [ $age_days -le $RETENTION_DAYS_WEEKLY ]; then
            # Entre 7 et 30 jours : garder seulement les dimanches (jour 7)
            if [ "$day_of_week" -eq 7 ]; then
                reason="hebdomadaire (dimanche)"
            else
                should_delete=true
                reason="non-dimanche dans période hebdo"
            fi
        elif [ $age_days -le $RETENTION_DAYS_MONTHLY ]; then
            # Entre 30 et 90 jours : garder seulement le 1er du mois
            if [ "$day_of_month" -eq "01" ]; then
                reason="mensuel (1er du mois)"
            else
                should_delete=true
                reason="non-1er dans période mensuelle"
            fi
        elif [ $age_days -le $RETENTION_DAYS_YEARLY ]; then
            # Entre 90 jours et 12 mois : garder seulement le 1er du mois
            if [ "$day_of_month" -eq "01" ]; then
                reason="archive mensuelle (1er du mois, 3-12 mois)"
            else
                should_delete=true
                reason="non-1er dans période archive"
            fi
        else
            # Plus de 12 mois : supprimer
            should_delete=true
            reason="trop ancien (>${RETENTION_DAYS_YEARLY}j / >12 mois)"
        fi
        
        if [ "$should_delete" = true ]; then
            log_message "INFO" "Suppression de $dir_name (âge: ${age_days}j, raison: $reason)"
            rm -rf "$backup_dir"
            ((deleted_count++))
        else
            log_message "INFO" "Conservation de $dir_name (âge: ${age_days}j, raison: $reason)"
            ((kept_count++))
        fi
    done
    
    log_message "INFO" "========================================"
    log_message "INFO" "Nettoyage terminé"
    log_message "INFO" "Dossiers supprimés : $deleted_count"
    log_message "INFO" "Dossiers conservés : $kept_count"
    log_message "INFO" "Taille total des dossiers conservés : $(du -sh ${bkpdir_local} 2>/dev/null | cut -f1)"
    log_message "INFO" "========================================"
}

# Exécuter le nettoyage après les backups
cleanup_old_backups

exit 0
