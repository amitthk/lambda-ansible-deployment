import json
import boto3
import logging
import os
import tempfile
import base64
import subprocess
import shutil
import zipfile
from typing import Dict, Any, Optional
import paramiko
from io import StringIO
import time

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

class AnsibleDeploymentLambda:
    def __init__(self):
        self.s3_client = boto3.client('s3')
        self.ssm_client = boto3.client('ssm')
        self.work_dir = None
        
    def get_secret_parameter(self, parameter_name: str, decrypt: bool = True) -> str:
        """Get parameter from AWS Systems Manager Parameter Store"""
        try:
            response = self.ssm_client.get_parameter(
                Name=parameter_name,
                WithDecryption=decrypt
            )
            return response['Parameter']['Value']
        except Exception as e:
            logger.error(f"Error retrieving parameter {parameter_name}: {str(e)}")
            raise
    
    def setup_work_directory(self) -> str:
        """Create and setup work directory for Ansible execution"""
        self.work_dir = tempfile.mkdtemp(prefix='ansible_deploy_')
        logger.info(f"Created work directory: {self.work_dir}")
        return self.work_dir
    
    def download_ansible_package(self, ansible_s3_bucket: str, ansible_s3_key: str) -> str:
        """Download and extract Ansible package from S3"""
        try:
            # Download Ansible package
            package_path = os.path.join(self.work_dir, 'ansible-package.zip')
            self.s3_client.download_file(ansible_s3_bucket, ansible_s3_key, package_path)
            logger.info(f"Downloaded Ansible package from s3://{ansible_s3_bucket}/{ansible_s3_key}")
            
            # Extract package
            ansible_dir = os.path.join(self.work_dir, 'ansible')
            with zipfile.ZipFile(package_path, 'r') as zip_ref:
                zip_ref.extractall(ansible_dir)
            
            logger.info(f"Extracted Ansible package to {ansible_dir}")
            return ansible_dir
            
        except Exception as e:
            logger.error(f"Error downloading Ansible package: {str(e)}")
            raise
    
    def create_inventory_file(self, ansible_dir: str, vm_hostname: str, vm_username: str, site: str) -> str:
        """Create dynamic inventory file for the target environment"""
        inventory_content = f"""[vm]
{vm_hostname} ansible_user={vm_username} ansible_connection=ssh ansible_python_interpreter=/usr/libexec/platform-python

[vm:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes'
site={site}
"""
        
        inventory_path = os.path.join(ansible_dir, 'hosts')
        with open(inventory_path, 'w') as f:
            f.write(inventory_content)
        
        logger.info(f"Created inventory file: {inventory_path}")
        return inventory_path
    
    def setup_ssh_key(self, ssh_key_content: str) -> str:
        """Setup SSH key for Ansible connectivity"""
        ssh_dir = os.path.expanduser('~/.ssh')
        os.makedirs(ssh_dir, exist_ok=True)
        
        key_path = os.path.join(ssh_dir, 'id_rsa')
        
        # Decode if base64 encoded
        try:
            decoded_key = base64.b64decode(ssh_key_content).decode('utf-8')
            ssh_key_content = decoded_key
        except Exception:
            # Already decoded
            pass
        
        with open(key_path, 'w') as f:
            f.write(ssh_key_content)
        
        os.chmod(key_path, 0o600)
        logger.info(f"SSH key setup completed: {key_path}")
        return key_path
    
    def execute_ansible_playbook(self, ansible_dir: str, inventory_path: str, 
                                 extra_vars: Dict[str, Any]) -> Dict[str, Any]:
        """Execute Ansible playbook"""
        try:
            # Change to ansible directory
            original_cwd = os.getcwd()
            os.chdir(ansible_dir)
            
            # Set environment variables for Ansible
            env = os.environ.copy()
            env['ANSIBLE_HOST_KEY_CHECKING'] = 'False'
            env['ANSIBLE_STDOUT_CALLBACK'] = 'yaml'
            env['ANSIBLE_GATHERING'] = 'explicit'
            
            # Convert extra_vars to command line format
            extra_vars_list = []
            for key, value in extra_vars.items():
                extra_vars_list.extend(['-e', f'{key}={value}'])
            
            # Construct ansible-playbook command
            cmd = [
                'ansible-playbook',
                '-i', inventory_path,
                'main.yml',
                '--ssh-common-args', '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes',
                '-vvv'
            ] + extra_vars_list
            
            logger.info(f"Executing command: {' '.join(cmd)}")
            
            # Execute playbook
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=900,  # 15 minutes timeout
                env=env
            )
            
            # Restore original directory
            os.chdir(original_cwd)
            
            return {
                'returncode': result.returncode,
                'stdout': result.stdout,
                'stderr': result.stderr,
                'success': result.returncode == 0
            }
            
        except subprocess.TimeoutExpired:
            logger.error("Ansible playbook execution timed out")
            return {
                'returncode': -1,
                'stdout': '',
                'stderr': 'Execution timed out after 15 minutes',
                'success': False
            }
        except Exception as e:
            logger.error(f"Error executing Ansible playbook: {str(e)}")
            return {
                'returncode': -1,
                'stdout': '',
                'stderr': str(e),
                'success': False
            }
    
    def get_inventory_mapping(self, site: str) -> Dict[str, str]:
        """Get VM details from SSM Parameter Store based on site"""
        try:
            # Get environment-specific parameters
            hostname = self.get_secret_parameter(f'/demoapp/vm/{site.lower()}/hostname', decrypt=False)
            username = self.get_secret_parameter(f'/demoapp/vm/{site.lower()}/username', decrypt=False)
            ssh_key = self.get_secret_parameter(f'/demoapp/vm/ssh-key', decrypt=True)
            
            # Get database configuration
            datasource_url = self.get_secret_parameter(f'/demoapp/vm/{site.lower()}/datasource_url', decrypt=True)
            db_username = self.get_secret_parameter(f'/demoapp/vm/{site.lower()}/db_username', decrypt=True)
            db_password = self.get_secret_parameter(f'/demoapp/vm/{site.lower()}/db_password', decrypt=True)
            
            return {
                'hostname': hostname,
                'username': username,
                'ssh_key': ssh_key,
                'datasource_url': datasource_url,
                'db_username': db_username,
                'db_password': db_password
            }
        except Exception as e:
            logger.error(f"Error getting inventory mapping for site {site}: {str(e)}")
            raise ValueError(f"No inventory mapping found for site: {site}")
    
    def cleanup(self):
        """Cleanup work directory"""
        if self.work_dir and os.path.exists(self.work_dir):
            shutil.rmtree(self.work_dir)
            logger.info(f"Cleaned up work directory: {self.work_dir}")

def lambda_handler(event, context):
    """Main Lambda handler function"""
    deployer = None
    try:
        # Parse input parameters
        body = json.loads(event.get('body', '{}')) if isinstance(event.get('body'), str) else event
        
        service_name = body.get('service_name')
        jar_timestamp = body.get('jar_timestamp') 
        site = body.get('site', 'sit1').upper()
        app_user = body.get('app_user', 'appuser')
        ansible_s3_bucket = body.get('ansible_s3_bucket', os.environ.get('ANSIBLE_S3_BUCKET'))
        ansible_s3_key = body.get('ansible_s3_key', 'ansible/ansible-playbooks.zip')
        artifacts_s3_bucket = body.get('artifacts_s3_bucket', os.environ.get('AWS_S3_BUCKET_REPOSITORY'))
        
        # Validate required parameters
        if not all([service_name, jar_timestamp, artifacts_s3_bucket, ansible_s3_bucket]):
            return {
                'statusCode': 400,
                'body': json.dumps({
                    'error': 'Missing required parameters: service_name, jar_timestamp, artifacts_s3_bucket, ansible_s3_bucket'
                })
            }
        
        logger.info(f"Starting Ansible deployment for {service_name} with timestamp {jar_timestamp}")
        logger.info(f"Target site: {site}")
        
        # Initialize deployment handler
        deployer = AnsibleDeploymentLambda()
        
        # Setup work directory
        deployer.setup_work_directory()
        
        # Get inventory mapping from SSM
        inventory = deployer.get_inventory_mapping(site)
        
        # Setup SSH key
        ssh_key_path = deployer.setup_ssh_key(inventory['ssh_key'])
        
        # Download Ansible package
        ansible_dir = deployer.download_ansible_package(ansible_s3_bucket, ansible_s3_key)
        
        # Create inventory file
        inventory_path = deployer.create_inventory_file(
            ansible_dir, inventory['hostname'], inventory['username'], site
        )
        
        # Prepare extra variables for Ansible
        extra_vars = {
            'service_name': service_name,
            'jar_timestamp': jar_timestamp,
            'aws_s3_bucket_repository': artifacts_s3_bucket,
            'aws_access_key_id': os.environ.get('AWS_ACCESS_KEY_ID'),
            'aws_secret_access_key': os.environ.get('AWS_SECRET_ACCESS_KEY'),
            'aws_default_region': os.environ.get('AWS_DEFAULT_REGION'),
            'site': site,
            'app_user': app_user,
            'datasource_url': inventory['datasource_url'],
            'db_username': inventory['db_username'],
            'db_password': inventory['db_password']
        }
        
        # Execute Ansible playbook
        logger.info("Executing Ansible playbook...")
        result = deployer.execute_ansible_playbook(ansible_dir, inventory_path, extra_vars)
        
        if result['success']:
            logger.info("Ansible deployment completed successfully!")
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'message': 'Deployment completed successfully',
                    'service_name': service_name,
                    'timestamp': jar_timestamp,
                    'site': site,
                    'target_vm': inventory['hostname'],
                    'ansible_output': result['stdout'][-2000:]  # Last 2000 chars to avoid size limits
                })
            }
        else:
            logger.error(f"Ansible deployment failed: {result['stderr']}")
            return {
                'statusCode': 500,
                'body': json.dumps({
                    'error': 'Deployment failed',
                    'ansible_stderr': result['stderr'][-2000:],
                    'ansible_stdout': result['stdout'][-2000:]
                })
            }
            
    except Exception as e:
        logger.error(f"Lambda deployment failed: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e),
                'message': 'Lambda deployment failed'
            })
        }
    finally:
        if deployer:
            deployer.cleanup()

# For local testing
if __name__ == "__main__":
    test_event = {
        'service_name': 'demoapp-backend',
        'jar_timestamp': '20250115-143000',
        'site': 'sit1',
        'app_user': 'appuser',
        'ansible_s3_bucket': 'your-ansible-bucket',
        'artifacts_s3_bucket': 'your-artifacts-bucket'
    }
    
    result = lambda_handler(test_event, None)
    print(json.dumps(result, indent=2))
