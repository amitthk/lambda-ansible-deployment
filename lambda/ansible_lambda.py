import os, json, tempfile, shutil, subprocess, logging, base64
import boto3
from typing import Dict, Any

logger = logging.getLogger()
logger.setLevel(os.getenv("LOG_LEVEL", "INFO"))

SECRETS_CLIENT = boto3.client('secretsmanager')
SSM_CLIENT = boto3.client('ssm')

def _copy_embedded_ansible(work_dir: str) -> str:
    base_dir = os.path.dirname(__file__)
    embedded_dir = os.path.join(base_dir, "ansible")
    bundle = os.path.join(base_dir, "ansible_bundle.zip")
    target = os.path.join(work_dir, "ansible")
    if os.path.isdir(embedded_dir):
        shutil.copytree(embedded_dir, target)
        logger.info("Copied embedded ansible directory")
    elif os.path.isfile(bundle):
        shutil.unpack_archive(bundle, work_dir)
        logger.info("Unpacked ansible_bundle.zip")
        # After unzip we expect ansible/ present
        if not os.path.isdir(target):
            raise RuntimeError("ansible directory missing after unzip")
    else:
        raise RuntimeError("No embedded ansible (directory or zip) found in package")
    return target

def _get_json_secret(secret_id: str) -> Dict[str, Any]:
    resp = SECRETS_CLIENT.get_secret_value(SecretId=secret_id)
    if 'SecretString' in resp:
        return json.loads(resp['SecretString'])
    return json.loads(base64.b64decode(resp['SecretBinary']).decode())

def _write_ssh_key(work_dir: str, secret_id: str) -> str:
    key_secret = SECRETS_CLIENT.get_secret_value(SecretId=secret_id)
    key_material = key_secret.get('SecretString') or base64.b64decode(key_secret['SecretBinary']).decode()
    key_path = os.path.join(work_dir, "id_rsa")
    with open(key_path, "w") as f:
        f.write(key_material.strip() + "\n")
    os.chmod(key_path, 0o600)
    logger.info("SSH key written")
    return key_path

def _create_inventory(ansible_dir: str, host: str, user: str, site: str) -> str:
    hosts_path = os.path.join(ansible_dir, "hosts")
    content = f"""[vm]
{host} ansible_user={user} ansible_connection=ssh ansible_python_interpreter=/usr/libexec/platform-python

[vm:vars]
site={site}
ansible_ssh_common_args=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes
"""
    with open(hosts_path, "w") as f:
        f.write(content)
    return hosts_path

def _run_playbook(ansible_dir: str, extra: Dict[str, Any], ssh_key_path: str) -> Dict[str, Any]:
    env = os.environ.copy()
    env["ANSIBLE_HOST_KEY_CHECKING"] = "False"
    env["ANSIBLE_STDOUT_CALLBACK"] = env.get("ANSIBLE_STDOUT_CALLBACK", "yaml")

    extra_args = []
    for k, v in extra.items():
        if v is None:
            continue
        extra_args.extend(["-e", f"{k}={v}"])

    cmd = [
        "ansible-playbook",
        "-i", os.path.join(ansible_dir, "hosts"),
        "main.yml",
        "--ssh-common-args", "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes",
        "-vv"
    ] + extra_args

    logger.info("Executing: %s", " ".join(cmd))
    result = subprocess.run(cmd, cwd=ansible_dir, capture_output=True, text=True, timeout=900, env=env)
    return {
        "returncode": result.returncode,
        "stdout": result.stdout[-20000:],
        "stderr": result.stderr[-20000:],
        "success": result.returncode == 0
    }

def lambda_handler(event, context):
    try:
        body = json.loads(event.get("body", "{}")) if isinstance(event, dict) and "body" in event else event
        service_name = body.get("service_name")
        jar_timestamp = body.get("jar_timestamp")
        site = body.get("site", "sit1").lower()
        app_user = body.get("app_user", "appadm")

        if not service_name or not jar_timestamp:
            return {"statusCode": 400, "body": json.dumps({"error": "service_name and jar_timestamp required"})}

        # Secrets layout (mirrors working GitHub Action):
        # demoapp/vm/{site}   -> JSON with VM_HOSTNAME, VM_USERNAME, DATASOURCE_URL, DB_USERNAME, DB_PASSWORD
        # demoapp/vm/ssh-key  -> private key (string)
        vm_secret_id = f"demoapp/vm/{site}"
        ssh_key_secret_id = "demoapp/vm/ssh-key"

        vm_data = _get_json_secret(vm_secret_id)
        vm_host = vm_data["VM_HOSTNAME"]
        vm_user = vm_data["VM_USERNAME"]
        datasource_url = vm_data.get("DATASOURCE_URL", "")
        db_username = vm_data.get("DB_USERNAME", "")
        db_password = vm_data.get("DB_PASSWORD", "")

        work_dir = tempfile.mkdtemp(prefix="ansible_exec_")
        try:
            ansible_dir = _copy_embedded_ansible(work_dir)
            ssh_key_path = _write_ssh_key(work_dir, ssh_key_secret_id)
            _create_inventory(ansible_dir, vm_host, vm_user, site)

            extra_vars = {
                "service_name": service_name,
                "jar_timestamp": jar_timestamp,
                "aws_s3_bucket_repository": os.getenv("AWS_S3_BUCKET_REPOSITORY"),
                "aws_access_key_id": os.getenv("AWS_ACCESS_KEY_ID", ""),
                "aws_secret_access_key": os.getenv("AWS_SECRET_ACCESS_KEY", ""),
                "aws_default_region": os.getenv("AWS_DEFAULT_REGION", "us-east-1"),
                "site": site,
                "app_user": app_user,
                "datasource_url": datasource_url,
                "db_username": db_username,
                "db_password": db_password
            }

            result = _run_playbook(ansible_dir, extra_vars, ssh_key_path)
            if result["success"]:
                return {
                    "statusCode": 200,
                    "body": json.dumps({
                        "message": "Deployment succeeded",
                        "service_name": service_name,
                        "timestamp": jar_timestamp,
                        "site": site,
                        "target_vm": vm_host,
                        "ansible_stdout_tail": result["stdout"][-2000:]
                    })
                }
            return {
                "statusCode": 500,
                "body": json.dumps({
                    "error": "Deployment failed",
                    "stderr_tail": result["stderr"][-4000:],
                    "stdout_tail": result["stdout"][-4000:]
                })
            }
        finally:
            shutil.rmtree(work_dir, ignore_errors=True)
    except Exception as e:
        logger.exception("Unhandled error")
        return {"statusCode": 500, "body": json.dumps({"error": str(e)})}

if __name__ == "__main__":
    print(json.dumps(lambda_handler({
        "service_name": "discovery-service",
        "jar_timestamp": "20250122-120000",
        "site": "sit1"
    }, None), indent=2))
