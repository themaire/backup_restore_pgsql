#!/bin/bash

# =============================================================================
# Script de restauration PostgreSQL - Interface interactive ncurses
# =============================================================================
# Restaure un schéma depuis un backup avec un préfixe de date
# Exemple : sitcenca -> sitcenca_20251225
# =============================================================================

# Chemin du script (pour trouver le .env)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Couleurs pour le terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration des logs
LOG_DIR="/var/log/backup_bdd"
LOG_FILE="${LOG_DIR}/restore_bdd.log"

# -----------------------------------------------------------------------------
# Initialisation des logs
# -----------------------------------------------------------------------------
function init_log() {
    # Créer le répertoire de logs s'il n'existe pas
    if [ ! -d "$LOG_DIR" ]; then
        sudo mkdir -p "$LOG_DIR" 2>/dev/null || mkdir -p "$LOG_DIR" 2>/dev/null
        sudo chmod 755 "$LOG_DIR" 2>/dev/null
    fi
    
    # Vérifier qu'on peut écrire dans le fichier de log
    if ! touch "$LOG_FILE" 2>/dev/null; then
        sudo touch "$LOG_FILE" 2>/dev/null
        sudo chmod 666 "$LOG_FILE" 2>/dev/null
    fi
}

# -----------------------------------------------------------------------------
# Fonction de logging
# -----------------------------------------------------------------------------
function log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Nettoyage des fichiers temporaires
# -----------------------------------------------------------------------------
function cleanup_temp_files() {
    # Supprimer les anciens fichiers temporaires de restauration (> 1 jour)
    find /tmp -name "restore_*.sql" -mtime +1 -delete 2>/dev/null
    find /tmp -name "restore_*.log" -mtime +1 -delete 2>/dev/null
    find /tmp -name "restore_verbose_*.log" -mtime +1 -delete 2>/dev/null
}

# -----------------------------------------------------------------------------
# Vérification des dépendances
# -----------------------------------------------------------------------------
function check_dependencies() {
    if ! command -v whiptail &> /dev/null; then
        echo -e "${RED}❌ ERREUR : whiptail n'est pas installé${NC}"
        echo "   Installez-le avec : sudo apt install whiptail"
        exit 1
    fi
    
    if ! command -v psql &> /dev/null; then
        echo -e "${RED}❌ ERREUR : psql n'est pas installé${NC}"
        echo "   Installez-le avec : sudo apt install postgresql-client"
        exit 1
    fi
    
    if ! command -v gunzip &> /dev/null; then
        echo -e "${RED}❌ ERREUR : gunzip n'est pas installé${NC}"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Chargement des credentials depuis .env
# -----------------------------------------------------------------------------
function load_env() {
    local ENV_FILE="${SCRIPT_DIR}/.env"
    
    if [ -f "$ENV_FILE" ]; then
        set -a
        source "$ENV_FILE"
        set +a
    else
        whiptail --title "❌ Erreur" --msgbox "Fichier .env introuvable !\n\nCopier .env.example vers .env et configurer vos credentials." 10 60
        exit 1
    fi
    
    # Vérifier les variables essentielles
    if [ -z "$PGHOST" ] || [ -z "$PGDATABASE" ] || [ -z "$PGUSER" ] || [ -z "$PGPASSWORD" ]; then
        whiptail --title "❌ Erreur" --msgbox "Variables PostgreSQL manquantes dans .env\n\nVérifiez PGHOST, PGDATABASE, PGUSER et PGPASSWORD." 10 60
        exit 1
    fi
    
    export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD
    
    # Répertoire de backup
    bkpdir_local="${BACKUP_DIR}"
    
    if [ -z "$bkpdir_local" ] || [ ! -d "$bkpdir_local" ]; then
        whiptail --title "❌ Erreur" --msgbox "Répertoire de backup introuvable !\n\nVérifiez BACKUP_DIR dans .env\nChemin actuel : $bkpdir_local" 10 60
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Sélection du dossier de date
# -----------------------------------------------------------------------------
function select_date_folder() {
    local folders=()
    local count=0
    
    # Lister les dossiers de backup (format YYYYMMDD)
    for dir in "$bkpdir_local"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
        if [ -d "$dir" ]; then
            local dir_name=$(basename "$dir")
            local formatted_date="${dir_name:0:4}-${dir_name:4:2}-${dir_name:6:2}"
            local file_count=$(ls -1 "$dir"/*.gz 2>/dev/null | wc -l)
            
            # Calculer la taille non compressée totale du dossier
            local total_uncompressed=0
            for gz_file in "$dir"/*.gz; do
                if [ -f "$gz_file" ]; then
                    local uncompressed_size=$(gzip -l "$gz_file" 2>/dev/null | awk 'NR==2 {print $2}')
                    total_uncompressed=$((total_uncompressed + uncompressed_size))
                fi
            done
            # Convertir en format lisible (KB, MB, GB)
            local size=$(numfmt --to=iec-i --suffix=B $total_uncompressed 2>/dev/null || echo "${total_uncompressed}B")
            
            folders+=("$dir_name" "📅 $formatted_date | 📁 $file_count fichiers | 💾 $size (décompressé)")
            ((count++))
        fi
    done
    
    if [ $count -eq 0 ]; then
        whiptail --title "❌ Erreur" --msgbox "Aucun dossier de backup trouvé dans :\n$bkpdir_local" 10 60
        exit 1
    fi
    
    # Afficher le menu de sélection (ordre inverse pour avoir les plus récents en premier)
    selected_date=$(whiptail --title "🗓️  Sélection de la date de backup" \
        --menu "\nChoisissez le backup à restaurer :\n\nRépertoire : $bkpdir_local" 20 70 10 \
        "${folders[@]}" 3>&1 1>&2 2>&3)
    
    if [ -z "$selected_date" ]; then
        echo -e "${YELLOW}Annulé par l'utilisateur${NC}"
        exit 0
    fi
    
    selected_folder="$bkpdir_local/$selected_date"
}

# -----------------------------------------------------------------------------
# Sélection du schéma à restaurer
# -----------------------------------------------------------------------------
function select_schema() {
    local schemas=()
    local count=0
    
    # Lister les fichiers .gz dans le dossier sélectionné
    for file in "$selected_folder"/sch_*.sql.gz; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            # Extraire le nom du schéma (sch_XXX.sql.gz -> XXX)
            local schema_name=$(echo "$filename" | sed 's/^sch_//' | sed 's/\.sql\.gz$//')
            # Taille non compressée
            local uncompressed_size=$(gzip -l "$file" 2>/dev/null | awk 'NR==2 {print $2}')
            local size=$(numfmt --to=iec-i --suffix=B $uncompressed_size 2>/dev/null || echo "${uncompressed_size}B")
            schemas+=("$schema_name" "💾 $size")
            ((count++))
        fi
    done
    
    if [ $count -eq 0 ]; then
        whiptail --title "❌ Erreur" --msgbox "Aucun fichier de backup trouvé dans :\n$selected_folder" 10 60
        exit 1
    fi
    
    # Afficher le menu de sélection
    selected_schema=$(whiptail --title "📦 Sélection du schéma" \
        --menu "\nChoisissez le schéma à restaurer :\n\nBackup du : $selected_date" 20 70 10 \
        "${schemas[@]}" 3>&1 1>&2 2>&3)
    
    if [ -z "$selected_schema" ]; then
        echo -e "${YELLOW}Annulé par l'utilisateur${NC}"
        exit 0
    fi
    
    backup_file="$selected_folder/sch_${selected_schema}.sql.gz"
}

# -----------------------------------------------------------------------------
# Confirmation et personnalisation du nom
# -----------------------------------------------------------------------------
function confirm_restore() {
    local default_name="${selected_schema}_${selected_date}"
    
    # Demander le nom du nouveau schéma
    new_schema_name=$(whiptail --title "✏️  Nom du schéma restauré" \
        --inputbox "\nLe schéma sera restauré avec un nouveau nom.\n\nSchéma original : $selected_schema\nBackup du : $selected_date\n\nEntrez le nom du nouveau schéma :" 15 60 \
        "$default_name" 3>&1 1>&2 2>&3)
    
    if [ -z "$new_schema_name" ]; then
        echo -e "${YELLOW}Annulé par l'utilisateur${NC}"
        exit 0
    fi
    
    # Confirmation finale
    whiptail --title "⚠️  Confirmation" \
        --yesno "\nVous allez restaurer :\n\n📦 Schéma source : $selected_schema\n📅 Backup du : $selected_date\n🆕 Nouveau schéma : $new_schema_name\n📍 Base de données : $PGDATABASE@$PGHOST\n\nConfirmer la restauration ?" 15 60
    
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}Restauration annulée${NC}"
        exit 0
    fi
}

# -----------------------------------------------------------------------------
# Vérification si le schéma existe déjà
# -----------------------------------------------------------------------------
function check_schema_exists() {
    local schema_exists=$(psql -t -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = '$new_schema_name'" 2>/dev/null | tr -d ' ')
    
    if [ "$schema_exists" = "1" ]; then
        # Récupérer des informations sur le schéma existant
        local existing_tables=$(psql -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$new_schema_name'" 2>/dev/null | tr -d ' ')
        local existing_size=$(psql -t -c "SELECT pg_size_pretty(SUM(pg_total_relation_size(quote_ident(table_schema) || '.' || quote_ident(table_name)))) FROM information_schema.tables WHERE table_schema = '$new_schema_name'" 2>/dev/null | tr -d ' ')
        
        # Si la taille est vide, mettre "0 bytes"
        [ -z "$existing_size" ] && existing_size="0 bytes"
        
        whiptail --title "⚠️  ATTENTION - Schéma existant détecté !" \
            --yesno "\n🚨 Le schéma '$new_schema_name' existe déjà !\n\n📊 Informations sur le schéma existant :\n   • Tables : $existing_tables\n   • Taille : $existing_size\n\n❓ Voulez-vous SUPPRIMER ce schéma et le remplacer\n   par la restauration ?\n\n⚠️  CETTE ACTION EST IRRÉVERSIBLE !\n   Toutes les données du schéma seront perdues." 18 65
        
        if [ $? -eq 0 ]; then
            # Deuxième confirmation pour être sûr
            whiptail --title "🔴 DERNIÈRE CONFIRMATION" \
                --yesno "\n⚠️  ÊTES-VOUS VRAIMENT SÛR ?\n\nVous allez supprimer définitivement :\n   • Schéma : $new_schema_name\n   • Tables : $existing_tables\n   • Taille : $existing_size\n\nTapez OUI pour confirmer." 14 55
            
            if [ $? -eq 0 ]; then
                echo -e "${YELLOW}🗑️  Suppression du schéma existant '$new_schema_name'...${NC}"
                psql -c "DROP SCHEMA IF EXISTS \"$new_schema_name\" CASCADE;" 2>/dev/null
                if [ $? -ne 0 ]; then
                    whiptail --title "❌ Erreur" --msgbox "Impossible de supprimer le schéma existant.\n\nVérifiez vos droits sur la base de données." 10 55
                    exit 1
                fi
                echo -e "${GREEN}      ✓ Schéma supprimé${NC}"
            else
                echo -e "${YELLOW}Restauration annulée par l'utilisateur${NC}"
                exit 0
            fi
        else
            # Proposer de changer le nom
            whiptail --title "💡 Suggestion" \
                --yesno "\nVoulez-vous choisir un autre nom pour le schéma restauré ?\n\nNom actuel : $new_schema_name" 10 55
            
            if [ $? -eq 0 ]; then
                # Redemander un nouveau nom
                local new_name=$(whiptail --title "✏️  Nouveau nom" \
                    --inputbox "\nEntrez un nouveau nom pour le schéma :" 10 55 \
                    "${new_schema_name}_v2" 3>&1 1>&2 2>&3)
                
                if [ -n "$new_name" ]; then
                    new_schema_name="$new_name"
                    # Vérifier à nouveau si ce nouveau nom existe
                    check_schema_exists
                else
                    echo -e "${YELLOW}Restauration annulée${NC}"
                    exit 0
                fi
            else
                echo -e "${YELLOW}Restauration annulée${NC}"
                exit 0
            fi
        fi
    fi
}

# -----------------------------------------------------------------------------
# Restauration du schéma
# -----------------------------------------------------------------------------
function restore_schema() {
    local temp_file="/tmp/restore_${selected_schema}_$$.sql"
    local verbose_log="/tmp/restore_verbose_$$.log"
    
    log_message "INFO" "Début restauration: $selected_schema -> $new_schema_name (backup: $selected_date)"
    
    # Affichage du début de la restauration
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}         🔄 RESTAURATION EN COURS                           ${BLUE}║${NC}"
    echo -e "${BLUE}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} Schéma source    : ${GREEN}$selected_schema${NC}"
    echo -e "${BLUE}║${NC} Nouveau schéma   : ${GREEN}$new_schema_name${NC}"
    echo -e "${BLUE}║${NC} Backup du        : ${GREEN}$selected_date${NC}"
    echo -e "${BLUE}║${NC} Base de données  : ${GREEN}$PGDATABASE${NC}"
    echo -e "${BLUE}║${NC} Serveur          : ${GREEN}$PGHOST${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Étape 1 : Décompression
    echo -e "${YELLOW}[1/4]${NC} 📦 Décompression du backup..."
    gunzip -c "$backup_file" > "$temp_file"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Erreur lors de la décompression${NC}"
        log_message "ERROR" "Échec décompression: $backup_file"
        rm -f "$temp_file"
        exit 1
    fi
    echo -e "${GREEN}      ✓ Décompression terminée${NC}"
    
    # Étape 2 : Modification du nom du schéma dans le fichier SQL
    echo -e "${YELLOW}[2/6]${NC} ✏️  Renommage du schéma dans le fichier SQL..."
    
    # Remplacer TOUTES les occurrences du nom de schéma :
    # - "schema" (entre guillemets doubles)
    sed -i "s/\"$selected_schema\"/\"$new_schema_name\"/g" "$temp_file"
    # - 'schema' (entre guillemets simples)
    sed -i "s/'$selected_schema'/'$new_schema_name'/g" "$temp_file"
    # - schema. (nom qualifié comme schema.table) - IMPORTANT !
    sed -i "s/\b$selected_schema\./$new_schema_name./g" "$temp_file"
    # - SCHEMA schema (dans CREATE SCHEMA, etc.)
    sed -i "s/SCHEMA $selected_schema/SCHEMA $new_schema_name/g" "$temp_file"
    # - search_path = schema (sans guillemets)
    sed -i "s/search_path = $selected_schema/search_path = $new_schema_name/g" "$temp_file"
    
    echo -e "${GREEN}      ✓ Renommage effectué${NC}"
    
    # Étape 3 : Nettoyage du fichier SQL
    echo -e "${YELLOW}[3/5]${NC} 🧹 Nettoyage du fichier SQL..."
    
    # Supprimer le CREATE SCHEMA du dump (on le crée nous-mêmes à l'étape 4)
    sed -i "/^CREATE SCHEMA $new_schema_name/d" "$temp_file"
    sed -i "/^CREATE SCHEMA \"$new_schema_name\"/d" "$temp_file"
    
    echo -e "${GREEN}      ✓ Nettoyage terminé${NC}"
    
    # Étape 4 : Création du schéma
    echo -e "${YELLOW}[4/5]${NC} 🆕 Création du schéma '$new_schema_name'..."
    psql -c "CREATE SCHEMA IF NOT EXISTS \"$new_schema_name\";" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Erreur lors de la création du schéma${NC}"
        log_message "ERROR" "Échec création schéma: $new_schema_name"
        rm -f "$temp_file"
        exit 1
    fi
    echo -e "${GREEN}      ✓ Schéma créé${NC}"
    
    # Étape 5 : Restauration des données
    echo -e "${YELLOW}[5/5]${NC} 📥 Restauration des données..."
    echo ""
    
    local start_time_global=$(date +%s)
    
    # Exécuter le SQL complet et capturer les erreurs
    local restore_errors=""
    restore_errors=$(psql -v ON_ERROR_STOP=0 -f "$temp_file" 2>&1 | tee "$verbose_log")
    
    local end_time_global=$(date +%s)
    local total_duration=$((end_time_global - start_time_global))
    
    # Récupérer la liste des tables RÉELLEMENT créées dans le schéma (depuis la BDD)
    local tables=($(psql -t -c "SELECT table_name FROM information_schema.tables WHERE table_schema = '$new_schema_name' AND table_type = 'BASE TABLE' ORDER BY table_name" 2>/dev/null | tr -d ' ' | grep -v '^$'))
    local total_tables=${#tables[@]}
    local total_rows=0
    
    # Afficher le résultat par table
    for table in "${tables[@]}"; do
        # Compter les lignes dans cette table
        local row_count=$(psql -t -c "SELECT COUNT(*) FROM \"$new_schema_name\".\"$table\"" 2>/dev/null | tr -d ' ')
        [ -z "$row_count" ] && row_count="0"
        
        local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
        total_rows=$((total_rows + row_count))
        
        # Affichage avec progression
        printf "      ${GREEN}[%s]${NC} ✓ Table ${BLUE}%-30s${NC} | ${GREEN}%6s lignes${NC}\n" \
            "$timestamp" "$table" "$row_count"
    done
    
    # Afficher les erreurs significatives s'il y en a
    if [ -n "$restore_errors" ]; then
        echo "$restore_errors" | while read line; do
            if [[ "$line" == *"ERROR"* ]] && [[ "$line" != *"already exists"* ]] && [[ "$line" != *"duplicate key"* ]]; then
                echo -e "${RED}      ⚠ $line${NC}"
            fi
        done
    fi
    
    echo ""
    echo -e "      ${GREEN}────────────────────────────────────────────────${NC}"
    echo -e "      📊 Total : ${BLUE}$total_tables tables${NC} | ${GREEN}$total_rows lignes${NC} | ⏱️  ${YELLOW}${total_duration}s${NC}"
    
    # Nettoyage des fichiers temporaires
    rm -f "$temp_file"
    rm -f "$verbose_log"
    
    # Vérification finale
    local table_count=$(psql -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$new_schema_name'" 2>/dev/null | tr -d ' ')
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}         ✅ RESTAURATION TERMINÉE                           ${GREEN}║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} Schéma créé      : ${BLUE}$new_schema_name${NC}"
    echo -e "${GREEN}║${NC} Tables restaurées: ${BLUE}$table_count${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Log de fin
    log_message "SUCCESS" "Restauration terminée: $new_schema_name ($table_count tables, $total_rows lignes, ${total_duration}s)"
}

# -----------------------------------------------------------------------------
# Fonction principale
# -----------------------------------------------------------------------------
function main() {
    clear
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║     🐘 RESTAURATION PostgreSQL - Interface Interactive     ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_dependencies
    init_log
    cleanup_temp_files
    load_env
    select_date_folder
    select_schema
    confirm_restore
    check_schema_exists
    restore_schema
}

# Exécution
main
