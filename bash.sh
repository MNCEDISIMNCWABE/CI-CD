#!/bin/bash

set -euo pipefail

# Configure Google Cloud authentication
# export GOOGLE_APPLICATION_CREDENTIALS="/Users/mncedisimncwabe/Downloads/hallowed-span-459710-s1-c41d79c9b56b.json"
# gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
# gcloud config set project hallowed-span-459710-s1

# -----------------------
# Google Cloud Configuration
# -----------------------
if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
    # Running in CI/CD - auth is already handled by google-github-actions/auth
    echo "ℹ️ Using application default credentials from environment"
    gcloud config set project hallowed-span-459710-s1
else
    # Local development fallback
    echo "ℹ️ Setting up local credentials"
    export GOOGLE_APPLICATION_CREDENTIALS="${HOME}/.config/gcloud/application_default_credentials.json"
    gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
    gcloud config set project hallowed-span-459710-s1
fi

# -----------------------
# Project Configuration
# -----------------------
PROJECT_ID="hallowed-span-459710-s1"
DATASET_ID="test_clustering"
LOCATION="US"
DEFAULT_SCHEDULE="every 24 hours"
SQL_DIR="./sql" 

# -----------------------
# Helper Functions
# -----------------------

# Function to escape JSON strings properly
escape_json() {
    local input="$1"
    printf '%s' "$input" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//'
}

# Function to parse filename and extract display name and schedule
parse_filename() {
    local filename="$1"
    local display_name=""
    local schedule=""
    
    # Remove .sql extension first
    local base_name="${filename%.sql}"
    
    # Check if filename contains a dash (indicating schedule is present)
    if [[ "$base_name" == *"-"* ]]; then
        # Split on the last dash to separate display name from schedule
        display_name="${base_name%-*}"
        schedule="${base_name##*-}"
    else
        # No schedule specified, use entire name as display name
        display_name="$base_name"
        schedule="$DEFAULT_SCHEDULE"
    fi
    
    # Clean up display name - remove copy numbers and IDs
    # Pattern: remove " copy" followed by optional space and numbers/letters
    display_name=$(echo "$display_name" | sed -E 's/ copy [0-9A-Za-z]*$//')
    
    # Trim whitespace
    display_name=$(echo "$display_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    schedule=$(echo "$schedule" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Set default if schedule is empty
    if [[ -z "$schedule" ]]; then
        schedule="$DEFAULT_SCHEDULE"
    fi
    
    echo "DISPLAY_NAME=\"$display_name\""
    echo "SCHEDULE=\"$schedule\""
}

# -----------------------
# Process Each SQL File
# -----------------------

# Get existing configs
echo "🔍 Fetching existing transfer configurations..."
CONFIGS=$(bq ls --transfer_config --transfer_location="$LOCATION" --project_id="$PROJECT_ID" --format=json)

# Check if SQL directory exists
if [[ ! -d "$SQL_DIR" ]]; then
    echo "❌ SQL directory not found: $SQL_DIR" >&2
    exit 1
fi

# Count SQL files
SQL_FILE_COUNT=$(find "$SQL_DIR" -name "*.sql" -type f | wc -l)
if [[ $SQL_FILE_COUNT -eq 0 ]]; then
    echo "⚠️  No SQL files found in: $SQL_DIR"
    exit 0
fi

echo "📁 Found $SQL_FILE_COUNT SQL file(s) in: $SQL_DIR"
echo ""

for SQL_FILE in "$SQL_DIR"/*.sql; do
    [[ -f "$SQL_FILE" ]] || continue  # Skip if no .sql files

    FILENAME=$(basename "$SQL_FILE")
    
    echo "🟡 Processing file: $FILENAME"

    # Parse filename to extract display name and schedule
    PARSED_OUTPUT=$(parse_filename "$FILENAME")
    eval "$PARSED_OUTPUT"

    echo "📝 Display Name: $DISPLAY_NAME"
    echo "⏰ Schedule: $SCHEDULE"

    # Read SQL query and validate it's not empty
    if [[ ! -s "$SQL_FILE" ]]; then
        echo "⚠️  Skipping empty file: $FILENAME"
        continue
    fi

    QUERY=$(<"$SQL_FILE")
    echo "📄 Read query from: $FILENAME"

    # Properly escape the query for JSON
    ESCAPED_QUERY=$(escape_json "$QUERY")
    PARAMS="{\"query\": \"$ESCAPED_QUERY\"}"

    echo "🔍 Checking for existing transfer config..."

    # Check if config already exists
    MATCHING_CONFIGS=$(echo "$CONFIGS" | jq -r --arg display_name "$DISPLAY_NAME" '.[] | select(.displayName == $display_name) | .name')
    CONFIG_NAME_OR_ID=$(echo "$MATCHING_CONFIGS" | head -n 1)

    if [[ -n "$CONFIG_NAME_OR_ID" ]]; then
        echo "🔁 Updating existing transfer config: $CONFIG_NAME_OR_ID"

        if bq update \
            --transfer_config \
            --display_name="$DISPLAY_NAME" \
            --params="$PARAMS" \
            --schedule="$SCHEDULE" \
            "$CONFIG_NAME_OR_ID"; then
            echo "✅ Updated '$DISPLAY_NAME' successfully with schedule '$SCHEDULE'."
        else
            echo "❌ Failed to update '$DISPLAY_NAME'." >&2
            exit 1
        fi
    else
        echo "➕ Creating new transfer config for: $DISPLAY_NAME"
        
        if bq mk \
            --transfer_config \
            --display_name="$DISPLAY_NAME" \
            --params="$PARAMS" \
            --schedule="$SCHEDULE" \
            --data_source=scheduled_query \
            --project_id="$PROJECT_ID" \
            --location="$LOCATION"; then
            echo "✅ Created '$DISPLAY_NAME' successfully with schedule '$SCHEDULE'."
        else
            echo "❌ Failed to create '$DISPLAY_NAME'." >&2
            exit 1
        fi
    fi

    echo ""
done

echo "🎉 All scheduled queries processed successfully."