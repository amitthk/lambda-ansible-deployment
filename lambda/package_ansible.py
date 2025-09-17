#!/usr/bin/env python3
"""
Script to package Ansible playbooks for Lambda deployment
This script creates a ZIP file containing the Ansible directory structure
"""

import os
import zipfile
import boto3
import argparse
import logging
from pathlib import Path

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def create_ansible_package(ansible_dir: str, output_file: str) -> str:
    """Create ZIP package of Ansible directory"""
    logger.info(f"Creating Ansible package from {ansible_dir}")
    
    with zipfile.ZipFile(output_file, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(ansible_dir):
            # Skip .git and __pycache__ directories
            dirs[:] = [d for d in dirs if d not in ['.git', '__pycache__', '.pytest_cache']]
            
            for file in files:
                if file.endswith(('.pyc', '.pyo', '.DS_Store')):
                    continue
                    
                file_path = os.path.join(root, file)
                arcname = os.path.relpath(file_path, os.path.dirname(ansible_dir))
                zipf.write(file_path, arcname)
                logger.debug(f"Added {arcname} to package")
    
    logger.info(f"Created Ansible package: {output_file}")
    return output_file

def upload_to_s3(file_path: str, bucket: str, key: str) -> str:
    """Upload file to S3"""
    logger.info(f"Uploading {file_path} to s3://{bucket}/{key}")
    
    s3_client = boto3.client('s3')
    s3_client.upload_file(file_path, bucket, key)
    
    s3_url = f"s3://{bucket}/{key}"
    logger.info(f"Uploaded to {s3_url}")
    return s3_url

def main():
    parser = argparse.ArgumentParser(description='Package Ansible playbooks for Lambda')
    parser.add_argument('--ansible-dir', required=True, help='Path to Ansible directory')
    parser.add_argument('--output', default='ansible-playbooks.zip', help='Output ZIP file name')
    parser.add_argument('--s3-bucket', help='S3 bucket to upload package')
    parser.add_argument('--s3-key', default='ansible/ansible-playbooks.zip', help='S3 key for package')
    parser.add_argument('--upload', action='store_true', help='Upload to S3 after creating package')
    
    args = parser.parse_args()
    
    # Validate ansible directory exists
    if not os.path.exists(args.ansible_dir):
        logger.error(f"Ansible directory not found: {args.ansible_dir}")
        return 1
    
    try:
        # Create package
        package_path = create_ansible_package(args.ansible_dir, args.output)
        
        # Upload to S3 if requested
        if args.upload:
            if not args.s3_bucket:
                logger.error("S3 bucket required for upload")
                return 1
            
            upload_to_s3(package_path, args.s3_bucket, args.s3_key)
        
        logger.info("Packaging completed successfully!")
        return 0
        
    except Exception as e:
        logger.error(f"Error: {str(e)}")
        return 1

if __name__ == "__main__":
    exit(main())
