#!/bin/bash

# Prevent window debug/warning output for kdialog and notifcations.
export QT_LOGGING_RULES="*.debug=false;kf.notifications.warning=false"

STEAM_ROOT="${HOME}/.local/share/Steam"
STEAM_USERDATA="${STEAM_ROOT}/userdata"

# Detect the active Steam user ID.
#   1. Check loginusers.vdf for the account marked MostRecent
#   2. loginusers.vdf keys are SteamID64; userdata folders use accountid
#      (lower 32 bits: steamid64 - 76561197960265728)
#   3. Fall back to the only non-zero userdata dir if loginusers.vdf is absent
#   4. If still ambiguous, pick the most recently modified dir
detect_steam_userid() {
    local loginusers="${STEAM_ROOT}/config/loginusers.vdf"
    local userid=""

    if [[ -f "$loginusers" ]]; then
        # Find the steamid64 of the MostRecent user
        local steamid64
        steamid64=$(awk '
            { gsub(/[^0-9]/, "", $0) }
            /^[0-9]{15,}$/ { current=$0 }
            /MostRecent/ { print current; exit }
        ' "$loginusers")

    if [[ -n "$steamid64" ]]; then
            # Convert SteamID64 -> accountid
            userid=$(( steamid64 - 76561197960265728 ))
        fi
    fi

    # Fallback: scan userdata dirs, skip 0 (anonymous)
    if [[ -z "$userid" || ! -d "${STEAM_USERDATA}/${userid}" ]]; then
        local candidates=()
        for dir in "${STEAM_USERDATA}"/*/; do
            local id; id=$(basename "$dir")
            [[ "$id" == "0" || ! "$id" =~ ^[0-9]+$ ]] && continue
            candidates+=("$id")
        done

        if [[ ${#candidates[@]} -eq 1 ]]; then
            userid="${candidates[0]}"
        elif [[ ${#candidates[@]} -gt 1 ]]; then
            # Pick the most recently modified one
            userid=$(for id in "${candidates[@]}"; do
                echo "$id $(stat -c %Y "${STEAM_USERDATA}/${id}" 2>/dev/null || echo 0)"
            done | sort -k2 -rn | awk 'NR==1{print $1}')
        fi
    fi

    echo "$userid"
}

STEAM_USERID=$(detect_steam_userid)

if [[ -z "$STEAM_USERID" ]]; then
    echo "Could not detect Steam user ID — shortcuts.vdf lookup disabled."
    SHORTCUTS_VDF=""
else
    SHORTCUTS_VDF="${STEAM_USERDATA}/${STEAM_USERID}/config/shortcuts.vdf"
fi

# ---------------------------------------------------------------------------
# Parse shortcuts.vdf (binary VDF) into associative arrays:
#   SHORTCUT_NAMES[appid] = "Game Name"
#   SHORTCUT_EXES[appid]  = "/path/to/game.exe"
# Uses only: od, tr, bash builtins
# ---------------------------------------------------------------------------
declare -A SHORTCUT_NAMES
declare -A SHORTCUT_EXES

parse_shortcuts_vdf() {
    [[ -f "$SHORTCUTS_VDF" ]] || return

    # Load all bytes as decimal integers into an array
    read -ra BYTES <<< "$(od -An -tu1 "$SHORTCUTS_VDF" | tr -s ' \n' ' ')"
    local len=${#BYTES[@]}
    local i=0

    # Read null-terminated string starting at BYTES[i], advance i
    read_cstr() {
        local -n _out=$1 _i=$2
        local s=""
        while [[ ${BYTES[$_i]} != "0" ]]; do
            s+="$(printf "\\$(printf '%03o' "${BYTES[$_i]}")")"
            let "_i++" || true
        done
        let "_i++" || true
        _out="$s"
    }

    # Read 4-byte little-endian uint32 at BYTES[i], advance i
    read_u32() {
        local -n _out=$1 _i=$2
        local b0=${BYTES[$_i]} b1=${BYTES[$((_i+1))]} \
              b2=${BYTES[$((_i+2))]} b3=${BYTES[$((_i+3))]}
        _out=$(( b0 + b1*256 + b2*65536 + b3*16777216 ))
        (( _i += 4 ))
    }

    local key val appid="" appname="" exe=""

    while (( i < len )); do
        local b=${BYTES[$i]}; (( i++ ))
        case $b in
            0)  # section open — read key, skip in
                read_cstr key i
                # Reset per-entry fields when entering a numbered entry (0,1,2...)
                if [[ "$key" =~ ^[0-9]+$ ]]; then
                    appid=""; appname=""; exe=""
                fi
                ;;
            8)  # section close — if we have a complete entry, store it
                if [[ -n "$appid" && -n "$appname" ]]; then
                    SHORTCUT_NAMES["$appid"]="$appname"
                    SHORTCUT_EXES["$appid"]="$exe"
                fi
                ;;
            1)  # string field
                read_cstr key i
                read_cstr val i
                case "$key" in
                    AppName) appname="$val" ;;
                    Exe)     exe="$val"     ;;
                esac
                ;;
            2)  # int32 field
                read_cstr key i
                read_u32 val i
                [[ "$key" == "appid" ]] && appid="$val"
                ;;
        esac
    done
}

# Genereal function to check for existing files
check_files_exist() {
    local filenames=("$@")  # Accept filenames as arguments

    for filename in "${filenames[@]}"; do
        if [ -f "$filename" ]; then
            return 0  # Return true if at least one file exists
        fi
    done

    return 1 # Exit the script if the file isn't found
}

# Check if we have kdialog installed.
filenames=('/usr/bin/kdialog' '/usr/local/bin/kdialog')
check_files_exist "${filenames[@]}"

if [ $? -ne 0 ]; then  # Check the exit status
    echo "This script depends on kdialog, please install it."
    exit
fi

# Sanitize game name by removing non-ASCII characters using Bash regex
sanitize_game_name() {
    local game_name="$1"
    # Use parameter expansion to filter out non-ASCII characters
    game_name="${game_name//[^[:ascii:]]/}"  # Remove non-ASCII characters
    echo "$game_name"
}

# Get all Steam library paths from libraryfolders.vdf
get_library_paths() {
    local library_folders_file="$HOME/.steam/steam/steamapps/libraryfolders.vdf"
    local paths=()

    if [ -f "$library_folders_file" ]; then
        while IFS= read -r line; do
            if [[ $line =~ \"path\"[[:space:]]+\"([^\"]+)\" ]]; then
                local path="${BASH_REMATCH[1]}"
                paths+=("$path/steamapps")
            fi
        done < <(grep '"path"' "$library_folders_file")
    else
        kdialog --title "Alert" --sorry "File not found: $library_folders_file, is steam installed?"
    fi

    echo "${paths[@]}"
}

# Get the game name from the app ID.
# Falls back to shortcuts.vdf lookup for non-Steam games.
get_game_name() {
    local app_id=$1
    local manifest_file="$2"

    if [ -f "$manifest_file" ]; then
        grep -oP '"name"\s*"\K[^"]+' "$manifest_file" | head -n 1
    elif [[ -n "${SHORTCUT_NAMES[$app_id]}" ]]; then
        echo "${SHORTCUT_NAMES[$app_id]} (Non-Steam Game)"
    fi
}

main_shebang() {
    # Get all library paths
    library_paths=($(get_library_paths))

    if [ ${#library_paths[@]} -eq 0 ]; then
        kdialog --title "Alert" --sorry "No library paths found. Please check your libraryfolders.vdf file."
        exit
    fi

    declare -a game_names
    declare -a app_ids
    declare -a prefix_paths
    local index=0

    # name_index_map[base_name] = array index — used for dedup at collection time
    # A real Steam entry (has .acf) always displaces a non-Steam one for the same name
    declare -A name_index_map

    # Collect games
    for path in "${library_paths[@]}"; do
        for dir in "$path/compatdata"/*; do
            if [ -d "$dir" ]; then
                app_id=$(basename "$dir")
                manifest_file="$path/appmanifest_$app_id.acf"
                game_name=$(get_game_name "$app_id" "$manifest_file")

                if [ -n "$game_name" ]; then
                    sanitized_game_name=$(sanitize_game_name "$game_name")
                    is_nonsteam=false
                    base_name="$sanitized_game_name"
                    if [[ "$sanitized_game_name" == *" (Non-Steam Game)" ]]; then
                        is_nonsteam=true
                        base_name="${sanitized_game_name% (Non-Steam Game)}"
                    fi

                    existing_idx="${name_index_map[$base_name]}"
                    if [[ -n "$existing_idx" ]]; then
                        # Already seen this name — only replace if current entry is
                        # a real Steam game displacing a non-Steam one
                        if [[ "$is_nonsteam" == false && \
                              "${game_names[$existing_idx]}" == *" (Non-Steam Game)" ]]; then
                            game_names[$existing_idx]="$sanitized_game_name"
                            app_ids[$existing_idx]="$app_id"
                            prefix_paths[$existing_idx]="$path/compatdata/$app_id"
                        fi
                        # otherwise keep whatever's already there, skip this one
                    else
                        name_index_map["$base_name"]="$index"
                        game_names[index]="$sanitized_game_name"
                        app_ids[index]="$app_id"
                        prefix_paths[index]="$path/compatdata/$app_id"
                        index=$((index + 1))
                    fi
                fi
            fi
        done
    done

    # Build an array of indices for active Steam prefixes
    indices=()
    for ((i = 0; i < index; i++)); do
        # Filter Proton entries
        if [[ "${game_names[i]}" =~ ^Proton\ (Experimental|Hotfix|Next) ]] || \
           [[ "${game_names[i]}" =~ ^Proton\ [[:digit:]]+(\.[[:digit:]]+)*.* ]]; then
            continue
        fi
        indices+=("$i")
    done

    # Sort indices by game_names
    sorted_indices=($(for i in "${indices[@]}"; do
        echo "$i ${game_names[i]}"
    done | sort -k2 | awk '{print $1}'))

    # Build the game_list for kdialog using sorted indices
    game_list=()
    for i in "${sorted_indices[@]}"; do
        game_list+=("$((i + 1))" "${game_names[i]} (${app_ids[i]})")
    done

    # Populate kdialog with active Steam prefixes
    selected_game=$(kdialog --geometry 600x400 --title "Select a prefix" --menu "Found prefixes:" "${game_list[@]}")

    # Validate input
    if [[ "$selected_game" =~ ^[1-9][0-9]*$ ]] && [ "$selected_game" -le "$index" ]; then
        selected_index=$((selected_game - 1))
        kdialog --title "Delete prefix" --yesno "Name: ${game_names[selected_index]}\nPath: ${prefix_paths[selected_index]}\n\nAre you sure you want to delete this prefix?"
        # Capture user input
        case $? in
            0)  
                # 0 - Yes
                # Make sure the prefix actually exists before trying to delete it, also make sure it contains compatdata in the path.
                # Also serves as error detection and a more secured way to delete the prefix.
                if [[ -d "${prefix_paths[selected_index]}" && "${prefix_paths[selected_index]}" == *"compatdata"* && "${prefix_paths[selected_index]}" != "/" ]];then
                    rm -rf "${prefix_paths[selected_index]}"
                    # Check if the deletion was successful
                    if [ ! -d "${prefix_paths[selected_index]}" ]; then
                        kdialog --msgbox "Successfully deleted prefix for ${game_names[selected_index]}"
                        main_shebang # Return to main dialog
                    else
                        kdialog --title "Alert" --sorry "Failed to delete prefix ${prefix_paths[selected_index]}"
                        main_shebang # Return to main dialog
                    fi
                else
                    kdialog --title "Prefix deletion failed" --sorry "Something is bonkers, ${prefix_paths[selected_index]} is not found!"
                    main_shebang # Return to main dialog
                fi
                ;;
            1)  
                # 1 - "No"
                # User did not want to delete the prefix, return to main prefix dialog.
                main_shebang
                ;;
            255)#!/bin/bash
#
# FIXME: non-steam games not supported
#

# Prevent window debug/warning output for kdialog and notifcations.
export QT_LOGGING_RULES="*.debug=false;kf.notifications.warning=false"


# Genereal function to check for existing files
check_files_exist() {
    local filenames=("$@")  # Accept filenames as arguments

    for filename in "${filenames[@]}"; do
        if [ -f "$filename" ]; then
            return 0  # Return true if at least one file exists
        fi
    done

    return 1 # Exit the script if the file isn't found
}

# Check if we have kdialog installed.
filenames=('/usr/bin/kdialog' '/usr/local/bin/kdialog')
check_files_exist "${filenames[@]}"

if [ $? -ne 0 ]; then  # Check the exit status
    echo "This script depends on kdialog, please install it."
    exit
fi

# Sanitize game name by removing non-ASCII characters using Bash regex
sanitize_game_name() {
    local game_name="$1"
    # Use parameter expansion to filter out non-ASCII characters
    game_name="${game_name//[^[:ascii:]]/}"  # Remove non-ASCII characters
    echo "$game_name"
}

# Get all Steam library paths from libraryfolders.vdf
get_library_paths() {
    local library_folders_file="$HOME/.steam/steam/steamapps/libraryfolders.vdf"
    local paths=()

    if [ -f "$library_folders_file" ]; then
        while IFS= read -r line; do
            if [[ $line =~ \"path\"[[:space:]]+\"([^\"]+)\" ]]; then
                local path="${BASH_REMATCH[1]}"
                paths+=("$path/steamapps")
            fi
        done < <(grep '"path"' "$library_folders_file")
    else
        kdialog --title "Alert" --sorry "File not found: $library_folders_file, is steam installed?"
    fi

    echo "${paths[@]}"
}

# Get the game name from the app ID
get_game_name() {
    local app_id=$1
    local manifest_file="$2"

    if [ -f "$manifest_file" ]; then
        grep -oP '"name"\s*"\K[^"]+' "$manifest_file" | head -n 1
    fi
}

main_shebang() {
    # Get all library paths
    library_paths=($(get_library_paths))

    if [ ${#library_paths[@]} -eq 0 ]; then
        kdialog --title "Alert" --sorry "No library paths found. Please check your libraryfolders.vdf file."
        exit
    fi

    declare -a game_names
    declare -a app_ids
    declare -a prefix_paths
    local index=0

    # Collect games
    for path in "${library_paths[@]}"; do
        for dir in "$path/compatdata"/*; do
            if [ -d "$dir" ]; then
                app_id=$(basename "$dir")
                manifest_file="$path/appmanifest_$app_id.acf"
                game_name=$(get_game_name "$app_id" "$manifest_file")

                if [ -n "$game_name" ]; then
                    # Sanitize game name
                    sanitized_game_name=$(sanitize_game_name "$game_name")

                    # Store game name and prefix path in arrays
                    game_names[index]="$sanitized_game_name"
                    app_ids[index]="$app_id"
                    prefix_paths[index]="$path/compatdata/$app_id"
                    index=$((index + 1))
                fi
            fi
        done
    done

    # Build an array of indices for active Steam prefixes
    indices=()
    for ((i = 0; i < index; i++)); do
        # Be sure to filter Proton from the list, for some reason it got a prefix too.
        if [[ ! "${game_names[i]}" =~ ^Proton\ (Experimental|Hotfix|Next) ]] && ! [[ ${game_names[i]} =~ ^Proton\ [[:digit:]]+(\.[[:digit:]]+)*.* ]];then
            indices+=("$i")
        fi
    done

    # Sort indices by game_names
    sorted_indices=($(for i in "${indices[@]}"; do
        echo "$i ${game_names[i]}"
    done | sort -k2 | awk '{print $1}'))

    # Build the game_list for kdialog using sorted indices
    game_list=()
    for i in "${sorted_indices[@]}"; do
        game_list+=("$((i + 1))" "${game_names[i]} (${app_ids[i]})")
    done

    # Populate kdialog with active Steam prefixes
    selected_game=$(kdialog --geometry 600x400 --title "Select a prefix" --menu "Found prefixes:" "${game_list[@]}")

    # Validate input
    if [[ "$selected_game" =~ ^[1-9][0-9]*$ ]] && [ "$selected_game" -le "$index" ]; then
        selected_index=$((selected_game - 1))
        kdialog --title "Delete prefix" --yesno "Name: ${game_names[selected_index]}:\nPath: ${prefix_paths[selected_index]}\n\nAre you sure you want to delete this prefix?"
        # Capture user input
        case $? in
            0)  
                # 0 - Yes
                # Make sure the prefix actually exists before trying to delete it, also make sure it contains compatdata in the path.
                # Also serves as error detection and a more secured way to delete the prefix.
                if [[ -d "${prefix_paths[selected_index]}" && "${prefix_paths[selected_index]}" == *"compatdata"* && "${prefix_paths[selected_index]}" != "/" ]];then
                    rm -rf "${prefix_paths[selected_index]}"
                    # Check if the deletion was successful
                    if [ ! -d "${prefix_paths[selected_index]}" ]; then
                        kdialog --msgbox "Successfully deleted prefix for ${game_names[selected_index]}"
                        main_shebang # Return to main dialog
                    else
                        kdialog --title "Alert" --sorry "Failed to delete prefix ${prefix_paths[selected_index]}"
                        main_shebang # Return to main dialog
                    fi
                else
                    kdialog --title "Prefix deletion failed" --sorry "Something is bonkers, ${prefix_paths[selected_index]} is not found!"
                    main_shebang # Return to main dialog
                fi
                ;;
            1)  
                # 1 - "No"
                # User did not want to delete the prefix, return to main prefix dialog.
                main_shebang
                ;;
            255)
                # 255 - Error or user closed dialog
                exit
                ;;
        esac
    else
        # User closed main dialog, silently quit
        exit
    fi
}

# Go Gadget, go
main_shebang

                # 255 - Error or user closed dialog
                exit
                ;;
        esac
    else
        # User closed main dialog, silently quit
        exit
    fi
}

# Parse shortcuts.vdf once at startup before doing anything else
parse_shortcuts_vdf

# Go Gadget, go
main_shebang
