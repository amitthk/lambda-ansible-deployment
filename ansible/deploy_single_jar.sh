#!/bin/bash

# Script to deploy a single JAR file locally without Ansible
# Usage: ./deploy_single_jar.sh <service_name> <timestamp> [--debug]
# Example: ./deploy_single_jar.sh gateway-service 20250722-143000

set -e  # Exit on any error

# Function to display usage
usage() {
    echo "Usage: $0 <service_name> <timestamp> [--debug]"
    echo ""
    echo "Arguments:"
    echo "  service_name: Name of the service to deploy (e.g., gateway-service)"
    echo "  timestamp:    Build timestamp for the JAR file (e.g., 20250722-143000)"
    echo "  --debug:      Enable debug mode with verbose output (optional)"
    echo ""
    echo "Examples:"
    echo "  $0 gateway-service 20250722-143000"
    echo "  $0 user-service 20250722-143000 --debug"
    echo ""
    echo "Environment variables (can be set in .env file):"
    echo "  APP_USER, AWS_S3_BUCKET_REPOSITORY, AWS_ACCESS_KEY_ID,"
    echo "  AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION,"
    echo "  DATASOURCE_URL, DB_USERNAME, DB_PASSWORD"
    exit 1
}

# Check if required arguments are provided
if [[ $# -lt 2 ]]; then
    echo "Error: Missing required arguments"
    usage
fi

SERVICE_NAME="$1"
JAR_TIMESTAMP="$2"
DEBUG_MODE=false

# Check for debug flag
if [[ "$3" == "--debug" ]] || [[ "$2" == "--debug" && $# -eq 3 ]]; then
    DEBUG_MODE=true
    echo " Debug mode enabled"
    # If debug is the second argument, swap it
    if [[ "$2" == "--debug" ]]; then
        JAR_TIMESTAMP="$3"
    fi
fi

# Enable verbose output in debug mode
if [[ "$DEBUG_MODE" == true ]]; then
    set -x
fi

# Load environment variables from .env file if it exists
if [[ -f .env ]]; then
    echo "Loading environment variables from .env file..."
    # Load the .env file
    source .env
    echo "✓ Environment variables loaded successfully"
else
    echo "Warning: .env file not found. Using existing environment variables."
fi

# Explicitly export AWS credentials immediately after loading
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION
export AWS_S3_BUCKET_REPOSITORY

# Validate required environment variables
REQUIRED_VARS=(
    "APP_USER" 
    "AWS_S3_BUCKET_REPOSITORY"
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY"
    "AWS_DEFAULT_REGION"
    "DATASOURCE_URL"
    "DB_USERNAME"
    "DB_PASSWORD"
)

echo "Validating required environment variables..."
missing_vars=()
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        missing_vars+=("$var")
    fi
done

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo "Error: The following required environment variables are missing:"
    printf '  %s\n' "${missing_vars[@]}"
    echo ""
    echo "Please set these variables in your .env file or environment."
    exit 1
fi

# Export the service-specific variables
export SERVICE_NAME
export JAR_TIMESTAMP

echo "✓ All required environment variables are set"

# Debug: Show AWS credentials being used (only in debug mode)
if [[ "$DEBUG_MODE" == true ]]; then
    echo " Debug: AWS Credentials Check"
    echo "  AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:10}..."
    echo "  AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:0:10}..."
    echo "  AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
    echo "  AWS_S3_BUCKET_REPOSITORY: $AWS_S3_BUCKET_REPOSITORY"
fi

echo ""
echo "Deployment Configuration:"
echo "  Service Name: $SERVICE_NAME"
echo "  JAR Timestamp: $JAR_TIMESTAMP"
echo "  S3 Bucket: $AWS_S3_BUCKET_REPOSITORY"
echo "  Target User: $APP_USER"
echo "  AWS Region: $AWS_DEFAULT_REGION"
echo ""

# Set deployment paths
JAR_PATH="/opt/apps/$SERVICE_NAME"
JAR_FILE="$JAR_PATH/$SERVICE_NAME.jar"
JAVA_HOME="/opt/apps/openjdk21"
JAVA_URL="https://corretto.aws/downloads/latest/amazon-corretto-21-x64-linux-jdk.tar.gz"
S3_ARTIFACT_PATH="artifacts/$JAR_TIMESTAMP/backend/$SERVICE_NAME.jar"

# Find AWS CLI path
AWS_CLI_PATH=""
if command -v aws >/dev/null 2>&1; then
    AWS_CLI_PATH=$(command -v aws)
    echo "✓ Found AWS CLI at: $AWS_CLI_PATH"
elif [[ -f "/opt/apps/venv3/bin/aws" ]]; then
    AWS_CLI_PATH="/opt/apps/venv3/bin/aws"
    echo "✓ Found AWS CLI at: $AWS_CLI_PATH (custom venv3)"
elif [[ -f "/usr/local/bin/aws" ]]; then
    AWS_CLI_PATH="/usr/local/bin/aws"
    echo "✓ Found AWS CLI at: $AWS_CLI_PATH"
elif [[ -f "/opt/homebrew/bin/aws" ]]; then
    AWS_CLI_PATH="/opt/homebrew/bin/aws"
    echo "✓ Found AWS CLI at: $AWS_CLI_PATH"
elif [[ -f "$HOME/.local/bin/aws" ]]; then
    AWS_CLI_PATH="$HOME/.local/bin/aws"
    echo "✓ Found AWS CLI at: $AWS_CLI_PATH"
else
    echo " AWS CLI not found. Please install AWS CLI or add it to PATH"
    echo "Common locations checked:"
    echo "  - /opt/apps/venv3/bin/aws (custom venv3)"
    echo "  - /usr/local/bin/aws"
    echo "  - /opt/homebrew/bin/aws (macOS with Homebrew)"
    echo "  - $HOME/.local/bin/aws"
    echo ""
    echo "To install AWS CLI:"
    echo "  - Custom venv3: /opt/apps/venv3/bin/pip install awscli"
    echo "  - macOS: brew install awscli"
    echo "  - Linux: pip install awscli"
    exit 1
fi

# Now verify AWS CLI can access S3 with the credentials from .env
echo "Verifying AWS credentials..."

# Double-check that AWS env vars are exported
if [[ "$DEBUG_MODE" == true ]]; then
    echo " Debug: Checking exported AWS environment variables:"
    env | grep AWS_ | sed 's/\(AWS_SECRET_ACCESS_KEY=\).*/\1[HIDDEN]/' | sed 's/\(AWS_ACCESS_KEY_ID=\)\(.\{10\}\).*/\1\2.../'
fi

# Test AWS CLI authentication
echo "Testing AWS CLI authentication..."
if "$AWS_CLI_PATH" sts get-caller-identity; then
    echo "✓ AWS credentials validated successfully"
else
    echo " AWS CLI cannot authenticate with provided credentials"
    echo ""
    echo "Debugging information:"
    echo "  AWS CLI Path: $AWS_CLI_PATH"
    echo "  AWS_ACCESS_KEY_ID length: ${#AWS_ACCESS_KEY_ID}"
    echo "  AWS_SECRET_ACCESS_KEY length: ${#AWS_SECRET_ACCESS_KEY}"
    echo "  AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
    echo ""
    echo "Troubleshooting steps:"
    echo "  1. Verify your .env file contains valid AWS credentials"
    echo "  2. Check that credentials have S3 access permissions"
    echo "  3. Try running: $AWS_CLI_PATH sts get-caller-identity manually"
    echo "  4. Run this script with --debug for more information"
    exit 1
fi

# Function to setup Java if not present
setup_java() {
    echo "Setting up Java environment..."
    
    if [[ -d "$JAVA_HOME" ]]; then
        echo "✓ Java already installed at $JAVA_HOME"
        return
    fi
    
    echo "Installing Amazon Corretto JDK 21..."
    sudo mkdir -p "$JAVA_HOME"
    
    # Download and extract Java
    curl -fsSL "$JAVA_URL" | sudo tar -xz -C "$JAVA_HOME" --strip-components=1
    
    # Set ownership
    sudo chown -R "$APP_USER:$APP_USER" "$JAVA_HOME"
    
    echo "✓ Java installation completed"
}

# Function to download JAR from S3
download_jar() {
    echo "Downloading JAR file from S3..."
    
    # Create application directory
    sudo mkdir -p "$JAR_PATH"
    sudo chown -R "$APP_USER:$APP_USER" "$JAR_PATH"
    
    # Download JAR file with better error handling
    echo "Downloading from: s3://$AWS_S3_BUCKET_REPOSITORY/$S3_ARTIFACT_PATH"
    echo "Downloading to: $JAR_FILE"
    
    if "$AWS_CLI_PATH" s3 cp "s3://$AWS_S3_BUCKET_REPOSITORY/$S3_ARTIFACT_PATH" "$JAR_FILE"; then
        echo "✓ JAR file downloaded successfully"
    else
        echo " Failed to download JAR file from S3"
        echo "Please check:"
        echo "  1. AWS credentials have read access to the S3 bucket"
        echo "  2. The file path is correct"
        echo "  3. Network connectivity to AWS"
        exit 1
    fi
    
    # Verify the downloaded file exists and is not empty
    if [[ ! -f "$JAR_FILE" ]]; then
        echo " JAR file was not created at $JAR_FILE"
        exit 1
    fi
    
    # Check file size
    file_size=$(stat -c%s "$JAR_FILE" 2>/dev/null || stat -f%z "$JAR_FILE" 2>/dev/null || echo "0")
    if [[ "$file_size" -eq 0 ]]; then
        echo " Downloaded JAR file is empty"
        rm -f "$JAR_FILE"
        exit 1
    fi
    
    echo "✓ JAR file size: $file_size bytes"
    
    # Set ownership and permissions
    sudo chown "$APP_USER:$APP_USER" "$JAR_FILE"
    sudo chmod 644 "$JAR_FILE"
    
    echo "✓ JAR file permissions set correctly"
}

# Function to create systemd service
create_service() {
    echo "Creating systemd service..."
    
    # Create service file
    sudo tee "/etc/systemd/system/$SERVICE_NAME.service" > /dev/null <<EOF
[Unit]
Description=$SERVICE_NAME
After=network.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$JAR_PATH
ExecStart=$JAVA_HOME/bin/java -jar $JAR_FILE
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

Environment=DATASOURCE_URL=$DATASOURCE_URL
Environment=DB_USERNAME=$DB_USERNAME
Environment=DB_PASSWORD=$DB_PASSWORD

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and enable service
    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    
    echo "✓ Systemd service created and enabled"
}

# Function to start service
start_service() {
    echo "Starting $SERVICE_NAME service..."
    
    # Stop service if running
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "Stopping existing service..."
        sudo systemctl stop "$SERVICE_NAME"
    fi
    
    # Start service
    sudo systemctl start "$SERVICE_NAME"
    
    # Check status
    sleep 5
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "✓ Service started successfully"
    else
        echo " Service failed to start"
        sudo systemctl status "$SERVICE_NAME" --no-pager
        exit 1
    fi
}

# Verify S3 artifact exists
S3_FULL_PATH="s3://$AWS_S3_BUCKET_REPOSITORY/$S3_ARTIFACT_PATH"
echo "Checking if JAR exists in S3..."
echo "Looking for: $S3_FULL_PATH"

# List the S3 directory to see what's available
S3_DIR="s3://$AWS_S3_BUCKET_REPOSITORY/artifacts/$JAR_TIMESTAMP/backend/"
echo "Listing files in S3 directory: $S3_DIR"
if "$AWS_CLI_PATH" s3 ls "$S3_DIR"; then
    echo "✓ Successfully listed S3 directory"
else
    echo " Failed to list S3 directory. Check if the timestamp and bucket are correct."
    echo "Bucket: $AWS_S3_BUCKET_REPOSITORY"
    echo "Path: artifacts/$JAR_TIMESTAMP/backend/"
    exit 1
fi

# Check if the specific JAR file exists
if "$AWS_CLI_PATH" s3 ls "$S3_FULL_PATH" >/dev/null 2>&1; then
    echo "✓ JAR file found in S3: $S3_FULL_PATH"
else
    echo " JAR file not found in S3: $S3_FULL_PATH"
    echo "Available files in the backend directory:"
    "$AWS_CLI_PATH" s3 ls "$S3_DIR" | grep -E '\.(jar|JAR)$' || echo "No JAR files found"
    echo ""
    echo "Please verify:"
    echo "  1. Service name is correct: $SERVICE_NAME"
    echo "  2. Timestamp is correct: $JAR_TIMESTAMP"
    echo "  3. S3 bucket is correct: $AWS_S3_BUCKET_REPOSITORY"
    exit 1
fi

echo ""
echo "Starting deployment..."
echo "----------------------------------------"

# Execute deployment steps
setup_java
download_jar
create_service
start_service

echo ""
echo "----------------------------------------"
echo " Deployment completed successfully!"
echo "Service '$SERVICE_NAME' with timestamp '$JAR_TIMESTAMP' has been deployed."

echo ""
echo "Deployment Summary:"
echo "  Service: $SERVICE_NAME"
echo "  Timestamp: $JAR_TIMESTAMP"
echo "  Status: SUCCESS"
echo "  JAR Location: $JAR_FILE"
echo "  Service Status: $(sudo systemctl is-active $SERVICE_NAME)"
echo ""
echo "To check service logs: sudo journalctl -u $SERVICE_NAME -f"
echo "To restart service: sudo systemctl restart $SERVICE_NAME"
echo "To stop service: sudo systemctl stop $SERVICE_NAME"
