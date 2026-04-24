#!/bin/bash
set -e  # Exit on any error

# Function to execute the script with passed environment variables
run_script() {
    local script_path="$1"  # First argument is the combined path to the script
    shift  # Shift the first argument (script path) so the remaining are environment variables

    # Initialize an empty array to store the environment variables
    local env_vars=()
    local env_vars_display=()

    # Always include GITHUB_TOKEN if it's set in the environment
    if [[ -n "${GITHUB_TOKEN}" ]]; then
        env_vars+=("GITHUB_TOKEN=${GITHUB_TOKEN}")
        env_vars_display+=("GITHUB_TOKEN=***")
    fi

    # Loop through the environment variable names and construct the env_vars array
    for var_name in "$@"; do
        if [[ -n "${!var_name}" ]]; then
            env_vars+=("${var_name}=${!var_name}")  # Add the env var in key=value format
            env_vars_display+=("${var_name}=${!var_name}")
        fi
    done

    # Convert the env_vars array into a space-separated string for export
    local env_vars_string="${env_vars[*]}"
    local env_vars_display_string="${env_vars_display[*]}"

    # Print and execute the script with the environment variables (mask sensitive values in output)
    echo "Executing: $script_path with environment variables: $env_vars_display_string"
    sudo bash -c "${env_vars_string} ${script_path}"
}