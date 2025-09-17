#!/bin/bash

# Load environment variables from .env file
if [[ -f .env ]]; then
  echo "Sourcing environment variables from .env"
  set -o allexport
  source .env
  set +o allexport
else
  echo "Warning: .env file not found. Proceeding with existing environment variables."
fi


# Ensure AWS_S3_BUCKET_REPOSITORY is set
if [[ -z "$AWS_S3_BUCKET_REPOSITORY" ]]; then
  echo "Error: AWS_S3_BUCKET_REPOSITORY environment variable is not set."
  exit 1
fi

# S3 path
S3_PATH="s3://$AWS_S3_BUCKET_REPOSITORY/artifacts/$JAR_TIMESTAMP/backend/"

# Loop through each JAR file in the S3 path
aws s3 ls "$S3_PATH" | awk '{print $4}' | grep '\.jar$' | while read -r jar_file; do
    # Remove .jar from the file name to get the service name
    SERVICE_NAME="${jar_file%.jar}"
    
    # Export SERVICE_NAME for use by anything downstream
    export SERVICE_NAME

    echo "Running playbook for: $jar_file"
    echo "SERVICE_NAME: $SERVICE_NAME"

    # Run the playbook with the JAR filename as an extra var
    ansible-playbook -i hosts -e "ansible_python_interpreter=/opt/apps/venv3/bin/python3.11" deploy-jar.yml -e "service_name=$SERVICE_NAME" -vvv
done

