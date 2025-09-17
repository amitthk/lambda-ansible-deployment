#!/bin/bash

# Simple test script to verify .env file is working
echo "Testing .env file loading..."

# Find AWS CLI path
AWS_CLI_PATH=""
if command -v aws >/dev/null 2>&1; then
    AWS_CLI_PATH=$(command -v aws)
elif [[ -f "/opt/apps/venv3/bin/aws" ]]; then
    AWS_CLI_PATH="/opt/apps/venv3/bin/aws"
elif [[ -f "/usr/local/bin/aws" ]]; then
    AWS_CLI_PATH="/usr/local/bin/aws"
elif [[ -f "/opt/homebrew/bin/aws" ]]; then
    AWS_CLI_PATH="/opt/homebrew/bin/aws"
elif [[ -f "$HOME/.local/bin/aws" ]]; then
    AWS_CLI_PATH="$HOME/.local/bin/aws"
else
    echo "❌ AWS CLI not found"
    echo "Checked locations:"
    echo "  - /opt/apps/venv3/bin/aws (custom venv3)"
    echo "  - /usr/local/bin/aws"
    echo "  - /opt/homebrew/bin/aws"
    echo "  - $HOME/.local/bin/aws"
    exit 1
fi

echo "✓ Found AWS CLI at: $AWS_CLI_PATH"

if [[ -f .env ]]; then
    echo "✓ .env file found"
    echo "Loading .env file..."
    source .env
    
    # Export AWS credentials
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_DEFAULT_REGION
    
    echo "Testing AWS CLI with loaded credentials..."
    echo "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:10}..."
    echo "AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:0:10}..."
    echo "AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
    
    echo ""
    echo "Running: $AWS_CLI_PATH sts get-caller-identity"
    "$AWS_CLI_PATH" sts get-caller-identity
    
    echo ""
    echo "Testing S3 access..."
    echo "Running: $AWS_CLI_PATH s3 ls s3://$AWS_S3_BUCKET_REPOSITORY/"
    "$AWS_CLI_PATH" s3 ls "s3://$AWS_S3_BUCKET_REPOSITORY/"
    
else
    echo "❌ .env file not found"
    exit 1
fi
