#!/bin/bash

# Enhanced Lambda Deployment Script for Ansible-based deployment
# This script packages and deploys the Lambda function with Ansible capabilities

set -e

# Configuration
FUNCTION_NAME="ansible-deployment-lambda"
RUNTIME="python3.11"
HANDLER="ansible_lambda.lambda_handler"
TIMEOUT=900  # 15 minutes
MEMORY_SIZE=1024
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Parse command line arguments
PACKAGE_ONLY=false
DEPLOY_ONLY=false
UPLOAD_ANSIBLE=false
ANSIBLE_S3_BUCKET=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --package-only)
            PACKAGE_ONLY=true
            shift
            ;;
        --deploy-only)
            DEPLOY_ONLY=true
            shift
            ;;
        --upload-ansible)
            UPLOAD_ANSIBLE=true
            shift
            ;;
        --ansible-s3-bucket)
            ANSIBLE_S3_BUCKET="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --package-only          Only create the Lambda package"
            echo "  --deploy-only           Only deploy existing package"
            echo "  --upload-ansible        Upload Ansible playbooks to S3"
            echo "  --ansible-s3-bucket     S3 bucket for Ansible playbooks"
            echo "  -h, --help              Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

check_aws_config() {
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS CLI not configured or credentials invalid"
        log_error "Please run: aws configure"
        exit 1
    fi
    log_info "AWS credentials validated"
}

create_lambda_role() {
    local role_name="AnsibleDeploymentLambdaRole"
    
    log_step "Creating IAM role: $role_name"
    
    # Trust policy for Lambda
    cat > /tmp/trust-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "lambda.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

    # Execution policy for Lambda
    cat > /tmp/lambda-execution-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "arn:aws:logs:*:*:*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::*",
                "arn:aws:s3:::*/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter",
                "ssm:GetParameters"
            ],
            "Resource": [
                "arn:aws:ssm:*:*:parameter/demoapp/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "kms:Decrypt"
            ],
            "Resource": [
                "arn:aws:kms:*:*:key/*"
            ]
        }
    ]
}
EOF

    # Check if role exists
    if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
        log_info "Role $role_name already exists"
    else
        aws iam create-role \
            --role-name "$role_name" \
            --assume-role-document file:///tmp/trust-policy.json \
            --description "Role for Ansible Deployment Lambda"
        log_info "Role $role_name created"
    fi
    
    # Create and attach custom policy
    local policy_name="AnsibleDeploymentLambdaPolicy"
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local policy_arn="arn:aws:iam::${account_id}:policy/$policy_name"
    
    if ! aws iam get-policy --policy-arn "$policy_arn" >/dev/null 2>&1; then
        aws iam create-policy \
            --policy-name "$policy_name" \
            --policy-document file:///tmp/lambda-execution-policy.json >/dev/null
        log_info "Created policy: $policy_name"
    else
        log_info "Policy $policy_name already exists"
    fi
    
    # Attach policy to role
    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "$policy_arn"
    
    # Get role ARN
    ROLE_ARN=$(aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text)
    log_info "Role ARN: $ROLE_ARN"
    
    # Clean up
    rm -f /tmp/trust-policy.json /tmp/lambda-execution-policy.json
}

package_ansible() {
    if [[ "$UPLOAD_ANSIBLE" == true ]]; then
        log_step "Packaging and uploading Ansible playbooks..."
        
        if [[ -z "$ANSIBLE_S3_BUCKET" ]]; then
            log_error "Ansible S3 bucket required for upload"
            exit 1
        fi
        
        python3 package_ansible.py \
            --ansible-dir ../ansible \
            --output ansible-playbooks.zip \
            --s3-bucket "$ANSIBLE_S3_BUCKET" \
            --upload
    fi
}

package_lambda() {
    log_step "Packaging Lambda + embedded Ansible content..."

    TEMP_DIR=$(mktemp -d)
    log_info "Temp dir: $TEMP_DIR"

    # Copy Python sources
    cp ansible_lambda.py "$TEMP_DIR/"
    cp deployment_lambda.py "$TEMP_DIR/" 2>/dev/null || true

    # Embed ansible directory
    if [[ -d ../ansible ]]; then
        log_info "Copying ansible directory"
        cp -R ../ansible "$TEMP_DIR/ansible"
        (cd "$TEMP_DIR" && zip -qr ansible_bundle.zip ansible)
    else
        log_warn "ansible directory not found at ../ansible"
    fi

    # Dependencies
    if [[ -f requirements.txt ]]; then
        log_info "Installing dependencies..."
        pip install --upgrade pip >/dev/null
        pip install --platform manylinux2014_x86_64 \
            --implementation cp --python-version 3.11 \
            --only-binary=:all: --upgrade \
            --target "$TEMP_DIR" -r requirements.txt
    fi

    # Build zip
    (cd "$TEMP_DIR" && zip -qr ../lambda-deployment.zip .)
    mv "$TEMP_DIR/../lambda-deployment.zip" ./lambda-deployment.zip
    rm -rf "$TEMP_DIR"

    local size_mb=$(( $(stat -c%s lambda-deployment.zip 2>/dev/null || stat -f%z lambda-deployment.zip) /1024/1024 ))
    log_info "Created lambda-deployment.zip (${size_mb}MB)"
    if (( size_mb > 240 )); then
        log_warn "Approaching Lambda size limits. Consider Layers."
    fi
}

deploy_lambda() {
    log_step "Deploying Lambda function: $FUNCTION_NAME"
    
    # Check if function exists
    if aws lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
        log_info "Updating existing Lambda function..."
        aws lambda update-function-code \
            --function-name "$FUNCTION_NAME" \
            --zip-file fileb://lambda-deployment.zip
        
        aws lambda update-function-configuration \
            --function-name "$FUNCTION_NAME" \
            --timeout "$TIMEOUT" \
            --memory-size "$MEMORY_SIZE"
    else
        log_info "Creating new Lambda function..."
        
        # Wait for role to be available
        log_info "Waiting for IAM role to be available..."
        sleep 10
        
        aws lambda create-function \
            --function-name "$FUNCTION_NAME" \
            --runtime "$RUNTIME" \
            --role "$ROLE_ARN" \
            --handler "$HANDLER" \
            --zip-file fileb://lambda-deployment.zip \
            --timeout "$TIMEOUT" \
            --memory-size "$MEMORY_SIZE" \
            --description "Ansible-based application deployment Lambda function"
    fi
    
    log_info "Lambda function deployed successfully!"
}

setup_environment_variables() {
    log_step "Setting environment variables..."
    aws lambda update-function-configuration \
      --function-name "$FUNCTION_NAME" \
      --environment Variables="{
        \"AWS_S3_BUCKET_REPOSITORY\":\"${AWS_S3_BUCKET_REPOSITORY:-demoapp-artifacts}\",
        \"LOG_LEVEL\":\"INFO\",
        \"ANSIBLE_STDOUT_CALLBACK\":\"yaml\",
        \"ANSIBLE_HOST_KEY_CHECKING\":\"False\"
      }" || log_warn "Env var update failed"
}

main() {
    log_info "Starting Enhanced Ansible Lambda deployment process..."
    log_info "Function Name: $FUNCTION_NAME"
    log_info "Region: $REGION"
    log_info "Memory: ${MEMORY_SIZE}MB"
    log_info "Timeout: ${TIMEOUT}s"
    
    check_aws_config
    
    if [[ "$DEPLOY_ONLY" == true ]]; then
        if [[ ! -f "lambda-deployment.zip" ]]; then
            log_error "Package file lambda-deployment.zip not found!"
            exit 1
        fi
        create_lambda_role
        deploy_lambda
        setup_environment_variables
    elif [[ "$PACKAGE_ONLY" == true ]]; then
        package_ansible
        package_lambda
        log_info "Package created. Deploy with: $0 --deploy-only"
    else
        # Full deployment
        create_lambda_role
        package_ansible
        package_lambda
        deploy_lambda
        setup_environment_variables
        
        # Clean up package
        rm -f lambda-deployment.zip ansible-playbooks.zip
    fi
    
    log_info "Deployment process completed!"
}

main "$@"