#!/bin/bash

# Test script for the Lambda deployment function
# This script helps test the Lambda function locally and remotely

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

# Function to test AWS connectivity
test_aws_connectivity() {
    log_test "Testing AWS connectivity..."
    
    if aws sts get-caller-identity >/dev/null 2>&1; then
        log_info "✅ AWS connectivity: OK"
        aws sts get-caller-identity
    else
        log_error "❌ AWS connectivity: FAILED"
        return 1
    fi
}

# Function to test S3 access
test_s3_access() {
    log_test "Testing S3 access..."
    
    local bucket="${AWS_S3_BUCKET_REPOSITORY:-sampleapp-artifacts}"
    
    if aws s3 ls "s3://$bucket/" >/dev/null 2>&1; then
        log_info "✅ S3 access: OK"
        log_info "Bucket: $bucket"
    else
        log_error "❌ S3 access: FAILED"
        log_error "Bucket: $bucket"
        return 1
    fi
}

# Function to test SSH key retrieval
test_ssh_key_retrieval() {
    log_test "Testing SSH key retrieval..."
    
    local key_param="SIT_VM_SSH_KEY"
    
    if aws ssm get-parameter --name "$key_param" --with-decryption >/dev/null 2>&1; then
        log_info "✅ SSH key retrieval: OK"
        log_info "Parameter: $key_param"
    else
        log_warn "⚠️  SSH key retrieval: NOT CONFIGURED"
        log_warn "Parameter: $key_param (create this for testing)"
    fi
}

# Function to test Lambda function exists
test_lambda_exists() {
    log_test "Testing Lambda function existence..."
    
    local function_name="sampleapp-deployment-lambda"
    
    if aws lambda get-function --function-name "$function_name" >/dev/null 2>&1; then
        log_info "✅ Lambda function exists: OK"
        log_info "Function: $function_name"
    else
        log_warn "⚠️  Lambda function: NOT DEPLOYED"
        log_warn "Run ./deploy.sh to deploy the function"
        return 1
    fi
}

# Function to test with JAR payload
test_jar_deployment() {
    log_test "Testing JAR deployment..."
    
    local payload_file="examples/test-payload-jar.json"
    
    if [[ ! -f "$payload_file" ]]; then
        log_error "Payload file not found: $payload_file"
        return 1
    fi
    
    log_info "Using payload: $payload_file"
    cat "$payload_file"
    
    echo ""
    log_info "Invoking Lambda function..."
    
    aws lambda invoke \
        --function-name sampleapp-deployment-lambda \
        --payload "file://$payload_file" \
        --cli-binary-format raw-in-base64-out \
        test-response-jar.json
    
    echo ""
    log_info "Response:"
    cat test-response-jar.json
    
    if grep -q '"statusCode": 200' test-response-jar.json; then
        log_info "✅ JAR deployment test: PASSED"
    else
        log_error "❌ JAR deployment test: FAILED"
        return 1
    fi
}

# Function to test with GraalVM payload
test_graalvm_deployment() {
    log_test "Testing GraalVM deployment..."
    
    local payload_file="examples/test-payload-graalvm.json"
    
    if [[ ! -f "$payload_file" ]]; then
        log_error "Payload file not found: $payload_file"
        return 1
    fi
    
    log_info "Using payload: $payload_file"
    cat "$payload_file"
    
    echo ""
    log_info "Invoking Lambda function..."
    
    aws lambda invoke \
        --function-name sampleapp-deployment-lambda \
        --payload "file://$payload_file" \
        --cli-binary-format raw-in-base64-out \
        test-response-graalvm.json
    
    echo ""
    log_info "Response:"
    cat test-response-graalvm.json
    
    if grep -q '"statusCode": 200' test-response-graalvm.json; then
        log_info "✅ GraalVM deployment test: PASSED"
    else
        log_error "❌ GraalVM deployment test: FAILED"
        return 1
    fi
}

# Function to run all tests
run_all_tests() {
    log_info "Running comprehensive Lambda deployment tests..."
    echo ""
    
    local tests_passed=0
    local tests_total=0
    
    # Test AWS connectivity
    ((tests_total++))
    if test_aws_connectivity; then
        ((tests_passed++))
    fi
    echo ""
    
    # Test S3 access
    ((tests_total++))
    if test_s3_access; then
        ((tests_passed++))
    fi
    echo ""
    
    # Test SSH key retrieval
    ((tests_total++))
    if test_ssh_key_retrieval; then
        ((tests_passed++))
    fi
    echo ""
    
    # Test Lambda function exists
    ((tests_total++))
    if test_lambda_exists; then
        ((tests_passed++))
        
        # Only run deployment tests if Lambda exists
        echo ""
        ((tests_total++))
        if test_jar_deployment; then
            ((tests_passed++))
        fi
        
        echo ""
        ((tests_total++))
        if test_graalvm_deployment; then
            ((tests_passed++))
        fi
    fi
    
    echo ""
    echo "=================================="
    log_info "Test Summary: $tests_passed/$tests_total tests passed"
    
    if [[ $tests_passed -eq $tests_total ]]; then
        log_info "🎉 All tests passed!"
        return 0
    else
        log_error "❌ Some tests failed"
        return 1
    fi
}

# Function to show usage
usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  --aws               Test AWS connectivity only"
    echo "  --s3                Test S3 access only"
    echo "  --ssh-key           Test SSH key retrieval only"
    echo "  --lambda            Test Lambda function existence only"
    echo "  --jar               Test JAR deployment only"
    echo "  --graalvm           Test GraalVM deployment only"
    echo "  --all               Run all tests (default)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                  # Run all tests"
    echo "  $0 --aws           # Test AWS connectivity"
    echo "  $0 --jar           # Test JAR deployment"
}

# Parse command line arguments
case "${1:-}" in
    --aws)
        test_aws_connectivity
        ;;
    --s3)
        test_s3_access
        ;;
    --ssh-key)
        test_ssh_key_retrieval
        ;;
    --lambda)
        test_lambda_exists
        ;;
    --jar)
        test_jar_deployment
        ;;
    --graalvm)
        test_graalvm_deployment
        ;;
    --all|"")
        run_all_tests
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
esac
