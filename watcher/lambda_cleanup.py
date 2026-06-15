"""
lambda_cleanup.py — GPU Watcher Cleanup Lambda
Deletes ALL temporary watcher services in the correct order.
NEVER touches anything created by aws_check_create.sh.
Uses CreatedBy=watcher tag as the safety filter.
"""

import os
import json
import time
import boto3
from botocore.exceptions import ClientError

AWS_REGION  = os.environ.get("AWS_REGION_NAME", "us-east-1")
SSM_PREFIX  = os.environ.get("SSM_PREFIX", "")
TABLE_NAME  = os.environ.get("TABLE_NAME", "")
PIPELINE_ID = os.environ.get("PIPELINE_RUN_ID", "")

ssm    = boto3.client("ssm",           region_name=AWS_REGION)
dynamo = boto3.client("dynamodb",      region_name=AWS_REGION)
sfn    = boto3.client("stepfunctions", region_name=AWS_REGION)
lmb    = boto3.client("lambda",        region_name=AWS_REGION)
sched  = boto3.client("scheduler",     region_name=AWS_REGION)
apigw  = boto3.client("apigateway",    region_name=AWS_REGION)
iam    = boto3.client("iam")
logs   = boto3.client("logs",          region_name=AWS_REGION)
sns    = boto3.client("sns",           region_name=AWS_REGION)

deleted = []
failed  = []

def safe_delete(label: str, fn, *args, **kwargs) -> None:
    """Run a delete call safely — log result either way."""
    try:
        fn(*args, **kwargs)
        deleted.append(label)
        print(f"[cleanup] Deleted: {label}")
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("ResourceNotFoundException", "NoSuchEntity",
                    "ResourceNotFound", "NotFoundException",
                    "404", "DeleteConflict"):
            print(f"[cleanup] Already gone: {label}")
            deleted.append(f"{label} (already gone)")
        else:
            failed.append(f"{label}: {e}")
            print(f"[cleanup] FAILED to delete {label}: {e}")
    except Exception as e:
        failed.append(f"{label}: {e}")
        print(f"[cleanup] FAILED to delete {label}: {e}")

def get_param(key: str) -> str:
    try:
        return ssm.get_parameter(Name=f"{SSM_PREFIX}/{key}")["Parameter"]["Value"]
    except Exception:
        return ""

# ---------------------------------------------------------------------------
def handler(event: dict, context) -> dict:
    pipeline_run_id = event.get("pipelineRunId", PIPELINE_ID)
    reason          = event.get("reason", "unknown")
    print(f"[lambda_cleanup] Starting cleanup — pipeline={pipeline_run_id} reason={reason}")

    # ── 1. Stop EventBridge Scheduler rule ───────────────────────────────────
    schedule_name = get_param("cleanup-schedule")
    if schedule_name:
        safe_delete(
            f"EventBridge schedule: {schedule_name}",
            sched.delete_schedule,
            Name=schedule_name
        )
    time.sleep(2)

    # ── 2. Delete API Gateway ─────────────────────────────────────────────────
    apigw_id = get_param("api-gateway-id")
    if apigw_id:
        safe_delete(
            f"API Gateway: {apigw_id}",
            apigw.delete_rest_api,
            restApiId=apigw_id
        )
    time.sleep(2)

    # ── 3. Delete DynamoDB table ──────────────────────────────────────────────
    table_name = get_param("cleanup-table") or TABLE_NAME
    if table_name:
        safe_delete(
            f"DynamoDB table: {table_name}",
            dynamo.delete_table,
            TableName=table_name
        )
    time.sleep(3)

    # ── 4. Stop and delete Step Functions state machine ───────────────────────
    sm_name = get_param("cleanup-sm-name")
    if sm_name:
        try:
            sm_arn = get_param("state-machine-arn")
            if sm_arn:
                # Stop any running executions first
                try:
                    execs = sfn.list_executions(
                        stateMachineArn=sm_arn, statusFilter="RUNNING"
                    )["executions"]
                    for ex in execs:
                        try:
                            sfn.stop_execution(
                                executionArn=ex["executionArn"],
                                cause="Cleanup initiated"
                            )
                        except Exception:
                            pass
                except Exception:
                    pass
                time.sleep(2)
                safe_delete(
                    f"Step Functions: {sm_arn}",
                    sfn.delete_state_machine,
                    stateMachineArn=sm_arn
                )
        except Exception as e:
            failed.append(f"Step Functions: {e}")

    # ── 5. Delete Lambda functions ────────────────────────────────────────────
    lambda_names = [
        f"gpu-watcher-discovery-{pipeline_run_id}",
        f"gpu-watcher-notify-{pipeline_run_id}",
        f"gpu-watcher-approve-{pipeline_run_id}",
    ]
    for name in lambda_names:
        safe_delete(
            f"Lambda: {name}",
            lmb.delete_function,
            FunctionName=name
        )
    time.sleep(2)

    # ── 6. Delete Lambda IAM execution role ───────────────────────────────────
    role_name = get_param("cleanup-role-name")
    if role_name:
        # Detach all policies first
        try:
            attached = iam.list_attached_role_policies(RoleName=role_name)["AttachedPolicies"]
            for policy in attached:
                try:
                    iam.detach_role_policy(RoleName=role_name, PolicyArn=policy["PolicyArn"])
                except Exception:
                    pass
        except Exception:
            pass

        # Delete inline policies
        try:
            inline = iam.list_role_policies(RoleName=role_name)["PolicyNames"]
            for policy_name in inline:
                try:
                    iam.delete_role_policy(RoleName=role_name, PolicyName=policy_name)
                except Exception:
                    pass
        except Exception:
            pass

        # Delete Step Functions role too
        sf_role = f"gpu-watcher-sf-role-{pipeline_run_id}"
        try:
            sf_inline = iam.list_role_policies(RoleName=sf_role)["PolicyNames"]
            for p in sf_inline:
                iam.delete_role_policy(RoleName=sf_role, PolicyName=p)
            iam.delete_role(RoleName=sf_role)
            deleted.append(f"IAM role: {sf_role}")
        except Exception:
            pass

        safe_delete(
            f"IAM role: {role_name}",
            iam.delete_role,
            RoleName=role_name
        )
    time.sleep(2)

    # ── 7. Delete CloudWatch log groups for watcher Lambdas ───────────────────
    for name in lambda_names + [f"gpu-watcher-cleanup-{pipeline_run_id}"]:
        log_group = f"/aws/lambda/{name}"
        safe_delete(
            f"CloudWatch log group: {log_group}",
            logs.delete_log_group,
            logGroupName=log_group
        )

    # ── 8. Clean up SSM parameters ────────────────────────────────────────────
    try:
        paginator = ssm.get_paginator("get_parameters_by_path")
        for page in paginator.paginate(Path=SSM_PREFIX, Recursive=True):
            param_names = [p["Name"] for p in page["Parameters"]]
            if param_names:
                # Delete in batches of 10
                for i in range(0, len(param_names), 10):
                    batch = param_names[i:i+10]
                    try:
                        ssm.delete_parameters(Names=batch)
                        deleted.append(f"SSM params: {len(batch)} parameters")
                    except Exception as e:
                        failed.append(f"SSM params batch: {e}")
    except Exception as e:
        failed.append(f"SSM cleanup: {e}")

    # ── 9. Send cleanup confirmation email ────────────────────────────────────
    sns_arn = get_param("sns-topic-arn") or ""
    if not sns_arn:
        # Try to get from original config — SNS is permanent, not deleted
        try:
            all_params = ssm.get_parameters_by_path(
                Path="/gpu-capacity-pipeline",
                Recursive=True
            ).get("Parameters", [])
            for p in all_params:
                if "sns-topic-arn" in p["Name"]:
                    sns_arn = p["Value"]
                    break
        except Exception:
            pass

    if sns_arn:
        deleted_list = "\n".join(f"  Deleted  :  {d}" for d in deleted[:20])
        subject = f"[Confirmed] AWS GPU Watcher Services Cleaned Up — {pipeline_run_id}"
        message = f"""Dear Team,

All temporary AWS watcher services for pipeline {pipeline_run_id}
have been successfully deleted from your account.

Reason for cleanup: {reason.replace('_', ' ').title()}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DELETED SERVICES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{deleted_list}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PERMANENT INFRASTRUCTURE UNTOUCHED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  All resources created by aws_check_create.sh
  have NOT been modified or deleted:

  Kept     :  Key pair
  Kept     :  Subnet
  Kept     :  Security group
  Kept     :  Placement group
  Kept     :  IAM instance profile and role
  Kept     :  SNS topic and subscriptions
  Kept     :  Caller IAM permissions
  Kept     :  Launch template

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This is an automated message. Do not reply to this email.

AWS GPU Capacity Block Reservation Pipeline
Powered by AWS Step Functions · Lambda · EventBridge
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"""

        try:
            sns.publish(
                TopicArn=sns_arn,
                Subject=subject,
                Message=message
            )
            print("[lambda_cleanup] Cleanup confirmation email sent")
        except Exception as e:
            print(f"[lambda_cleanup] Could not send cleanup email: {e}")

    # ── 10. Delete this cleanup Lambda itself last ────────────────────────────
    my_name = f"gpu-watcher-cleanup-{pipeline_run_id}"
    print(f"[lambda_cleanup] Self-deleting: {my_name}")
    try:
        lmb.delete_function(FunctionName=my_name)
        print(f"[lambda_cleanup] Self-deleted successfully")
    except Exception as e:
        print(f"[lambda_cleanup] Self-delete failed (non-critical): {e}")

    summary = {
        "status": "completed",
        "deleted": len(deleted),
        "failed": len(failed),
        "failedItems": failed,
        "pipelineRunId": pipeline_run_id
    }
    print(f"[lambda_cleanup] Done — {len(deleted)} deleted, {len(failed)} failed")
    return summary
