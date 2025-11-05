#!/bin/bash
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
    index=0

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

    # Create a list of active prefixes for kdialog
    game_list=()
    for ((i = 0; i < index; i++)); do
        # Be sure to filter Proton from the list, for some reason it got a prefix too.
        if [[ ! "${game_names[i]}" =~ ^Proton\ (Experimental|Hotfix|Next) ]] && ! [[ ${game_names[i]} =~ ^Proton\ [[:digit:]]+(\.[[:digit:]]+)*.* ]];then
            game_list+=("$((i + 1))" "${game_names[i]} (${app_ids[i]})")
        fi
    done

    # Populate kdialog with active steam prefixes
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