"""
lambda_approve.py — GPU Watcher Approval Handler Lambda  (updated)

CHANGES FROM ORIGINAL:
  - Removed YES / WAIT / NO per-AZ token handlers
  - Removed invalidate_all_other_tokens()
  - Added 'proceed' decision handler — validates proceed token,
    writes approval-decision=proceed to SSM, triggers final confirmation email
  - CONFIRM / CANCEL final confirmation handlers unchanged
  - RETRY / QUIT timeout handlers unchanged
  - Added STOP / STOP_TERMINATE / RESTART control handlers (new feature)
"""

import os
import json
import boto3
from datetime import datetime

AWS_REGION  = os.environ.get("AWS_REGION_NAME", "us-east-1")
SSM_PREFIX  = os.environ.get("SSM_PREFIX", "")
TABLE_NAME  = os.environ.get("TABLE_NAME", "")
PIPELINE_ID = os.environ.get("PIPELINE_RUN_ID", "")

ssm    = boto3.client("ssm",           region_name=AWS_REGION)
dynamo = boto3.resource("dynamodb",    region_name=AWS_REGION)
sns    = boto3.client("sns",           region_name=AWS_REGION)
sfn    = boto3.client("stepfunctions", region_name=AWS_REGION)
lmb    = boto3.client("lambda",        region_name=AWS_REGION)

# ---------------------------------------------------------------------------
# HTML response templates
# ---------------------------------------------------------------------------

HTML_OK = """<!DOCTYPE html><html><body style="font-family:Arial,sans-serif;max-width:600px;margin:60px auto;text-align:center;">
<div style="background:#e8f5e9;border-radius:12px;padding:40px;">
<h2 style="color:#2e7d32;">&#10003; {title}</h2>
<p style="color:#555;">{message}</p>
<p style="color:#888;font-size:12px;margin-top:30px;">Automated message — AWS GPU Capacity Block Reservation Pipeline.</p>
</div></body></html>"""

HTML_ALREADY = """<!DOCTYPE html><html><body style="font-family:Arial,sans-serif;max-width:600px;margin:60px auto;text-align:center;">
<div style="background:#fff3e0;border-radius:12px;padding:40px;">
<h2 style="color:#e65100;">&#8505; {title}</h2>
<p style="color:#555;">{message}</p>
</div></body></html>"""

HTML_EXPIRED = """<!DOCTYPE html><html><body style="font-family:Arial,sans-serif;max-width:600px;margin:60px auto;text-align:center;">
<div style="background:#fce4ec;border-radius:12px;padding:40px;">
<h2 style="color:#c62828;">&#8855; Link Expired</h2>
<p style="color:#555;">This approval link has expired or is invalid. Please check your inbox for a newer email, or contact your AWS administrator.</p>
</div></body></html>"""

HTML_WARN = """<!DOCTYPE html><html><body style="font-family:Arial,sans-serif;max-width:600px;margin:60px auto;text-align:center;">
<div style="background:#fff8e1;border-radius:12px;padding:40px;">
<h2 style="color:#f57f17;">&#9888; {title}</h2>
<p style="color:#555;">{message}</p>
</div></body></html>"""

def html_response(body: str, status: int = 200) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "text/html"},
        "body": body
    }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_param(key: str) -> str:
    try:
        return ssm.get_parameter(Name=f"{SSM_PREFIX}/{key}")["Parameter"]["Value"]
    except Exception:
        return ""

def put_param(key: str, value: str) -> None:
    try:
        ssm.put_parameter(Name=f"{SSM_PREFIX}/{key}", Value=value,
                          Type="String", Overwrite=True)
    except Exception as e:
        print(f"[WARN] SSM put {key}: {e}")

def get_table():
    return dynamo.Table(TABLE_NAME)

def get_token_item(prefix: str, token: str) -> dict:
    try:
        resp = get_table().get_item(Key={"pk": f"{prefix}{token}"})
        return resp.get("Item", {})
    except Exception:
        return {}

def update_token_status(prefix: str, token: str, status: str) -> None:
    try:
        get_table().update_item(
            Key={"pk": f"{prefix}{token}"},
            UpdateExpression="SET #s=:s, updatedAt=:t",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":s": status,
                ":t": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
            }
        )
    except Exception as e:
        print(f"[WARN] update_token_status {prefix}{token}: {e}")

def invoke_notify(action: str, extra: dict = None) -> None:
    try:
        payload = {"action": action, "pipelineRunId": PIPELINE_ID}
        if extra:
            payload.update(extra)
        lmb.invoke(
            FunctionName=f"gpu-watcher-notify-{PIPELINE_ID}",
            InvocationType="Event",
            Payload=json.dumps(payload).encode(),
        )
    except Exception as e:
        print(f"[WARN] invoke_notify {action}: {e}")

def invoke_cleanup(reason: str) -> None:
    try:
        lmb.invoke(
            FunctionName=f"gpu-watcher-cleanup-{PIPELINE_ID}",
            InvocationType="Event",
            Payload=json.dumps({
                "pipelineRunId": PIPELINE_ID,
                "reason":        reason
            }).encode(),
        )
        print(f"[lambda_approve] Cleanup triggered: {reason}")
    except Exception as e:
        print(f"[WARN] invoke_cleanup: {e}")

def invoke_infra_cleanup() -> None:
    """
    Trigger deletion of permanent infrastructure resources
    (the 8 resources from aws_check_create.sh) via lambda_infra_cleanup.
    Falls back gracefully if that Lambda does not exist yet.
    """
    try:
        lmb.invoke(
            FunctionName=f"gpu-watcher-infra-cleanup-{PIPELINE_ID}",
            InvocationType="Event",
            Payload=json.dumps({
                "pipelineRunId": PIPELINE_ID,
                "reason":        "user_stop_terminate"
            }).encode(),
        )
        print(f"[lambda_approve] Infra cleanup triggered")
    except Exception as e:
        print(f"[WARN] invoke_infra_cleanup: {e} — "
              f"run bash cleanup_infra.sh manually if needed")

# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------

def handler(event: dict, context) -> dict:
    params          = event.get("queryStringParameters") or {}
    token           = params.get("token",    "")
    decision        = params.get("decision", "").lower()
    pipeline_run_id = params.get("pid",      PIPELINE_ID)

    print(f"[lambda_approve] token={token} decision={decision}")

    if not token or not decision:
        return html_response(
            HTML_ALREADY.format(
                title="Invalid Request",
                message="This link is missing required parameters."
            ), 400
        )

    # ════════════════════════════════════════════════════════════
    # PIPELINE CONTROL LINKS  (stop / stop_terminate / restart)
    # Sent in every heartbeat and capacity-found email
    # ════════════════════════════════════════════════════════════
    if token.startswith("ctrl-"):

        # Guard: only act once
        ctrl_state = get_param("control-decision")
        if ctrl_state in ("stop", "stop_terminate", "restart"):
            return html_response(HTML_ALREADY.format(
                title="Already Actioned",
                message=(f"A control action ({ctrl_state}) was already "
                         f"applied to this pipeline run.")
            ))

        if decision == "stop":
            put_param("control-decision", "stop")
            invoke_cleanup("user_stop")
            return html_response(HTML_OK.format(
                title="Pipeline Stopped",
                message=(
                    "The watcher has been stopped. All temporary AWS "
                    "watcher services (Step Functions, Lambda, DynamoDB, "
                    "API Gateway) will be deleted shortly. Your permanent "
                    "infrastructure (key pair, subnet, security group, "
                    "placement group, IAM profile, SNS topic, launch "
                    "template) has not been touched. No Capacity Block "
                    "was purchased."
                )
            ))

        if decision == "stop_terminate":
            put_param("control-decision", "stop_terminate")
            # Step 1 — delete watcher services
            invoke_cleanup("user_stop_terminate")
            # Step 2 — delete permanent infra
            invoke_infra_cleanup()
            return html_response(HTML_WARN.format(
                title="Pipeline Stopped — All Resources Being Deleted",
                message=(
                    "The watcher has been stopped and ALL resources are "
                    "being deleted — including your permanent "
                    "infrastructure (key pair, subnet, security group, "
                    "placement group, IAM profile, SNS topic, launch "
                    "template). Your AWS account will be in a clean state. "
                    "Run bash main.sh to start a completely fresh pipeline."
                )
            ))

        if decision == "restart":
            put_param("control-decision", "restart")
            # Cleanup current run then redeploy is handled by Step Functions
            # reset_watcher action — signal it here
            put_param("retry-quit-decision", "retry")
            return html_response(HTML_OK.format(
                title="Pipeline Restarting",
                message=(
                    "The current pipeline run is being reset. A fresh "
                    "48-hour search window will begin immediately using "
                    "the same configuration. You will receive a new "
                    "pipeline started email shortly."
                )
            ))

        return html_response(HTML_ALREADY.format(
            title="Unknown Control Action",
            message=f"Unrecognised control decision: {decision}"
        ), 400)

    # ════════════════════════════════════════════════════════════
    # TIMEOUT RETRY / QUIT
    # ════════════════════════════════════════════════════════════
    if token.startswith("timeout-"):
        if decision == "retry":
            put_param("retry-quit-decision", "retry")
            return html_response(HTML_OK.format(
                title="Retry Confirmed",
                message=(
                    "A fresh 48-hour search window has started. "
                    "The attempt counter has been reset. You will "
                    "receive an email when capacity becomes available "
                    "or when the new window expires."
                )
            ))

        if decision == "quit":
            put_param("retry-quit-decision", "quit")
            invoke_cleanup("user_quit")
            return html_response(HTML_OK.format(
                title="Pipeline Stopped",
                message=(
                    "The pipeline has been stopped. All temporary AWS "
                    "watcher services will be deleted shortly. Your "
                    "permanent infrastructure has not been touched. "
                    "No charges were incurred."
                )
            ))

    # ════════════════════════════════════════════════════════════
    # PROCEED — NEW HANDLER
    # User clicked PROCEED TO CONFIRMATION from capacity found email
    # ════════════════════════════════════════════════════════════
    if decision == "proceed":
        token_item = get_token_item("proceed-token-", token)

        if not token_item:
            return html_response(HTML_EXPIRED)

        current_status = token_item.get("status", "")

        if current_status == "used":
            return html_response(HTML_ALREADY.format(
                title="Already Proceeded",
                message=(
                    "You have already clicked PROCEED for this offering. "
                    "Please check your inbox for the final confirmation email."
                )
            ))

        if current_status == "expired":
            return html_response(HTML_EXPIRED)

        # Mark token as used
        update_token_status("proceed-token-", token, "used")

        # Write proceed signal to SSM — Step Functions polls this
        put_param("approval-decision", "proceed")

        # Load offering and trigger final confirmation email
        offering_raw = token_item.get("offeringDetails", "{}")
        offering     = json.loads(offering_raw) if offering_raw else {}

        if offering:
            invoke_notify("send_final_confirmation", {
                "token":    token,
                "offering": offering
            })

        region = offering.get("Region",           "N/A")
        az     = offering.get("Availability Zone", "N/A")
        fee    = offering.get("Upfront Fee",       "N/A")

        return html_response(HTML_OK.format(
            title="Proceeding to Final Confirmation",
            message=(
                f"Your selection for {region} / {az} ({fee}) has been "
                f"received. A final confirmation email has been sent to "
                f"you. Please check your inbox and click CONFIRM PURCHASE "
                f"to complete the reservation. That email expires in "
                f"30 minutes. Clicking CONFIRM is the only step that "
                f"charges your account."
            )
        ))

    # ════════════════════════════════════════════════════════════
    # FINAL CONFIRMATION — CONFIRM or CANCEL
    # ════════════════════════════════════════════════════════════
    if token.startswith("final-"):
        token_item = get_token_item("final-token-", token)

        if not token_item:
            return html_response(HTML_EXPIRED)

        current_status = token_item.get("status", "")

        if current_status == "confirmed":
            return html_response(HTML_ALREADY.format(
                title="Already Confirmed",
                message=(
                    "This reservation has already been confirmed and "
                    "is being processed. Check your inbox for the "
                    "pipeline completion email."
                )
            ))

        if current_status == "cancelled":
            return html_response(HTML_ALREADY.format(
                title="Already Cancelled",
                message="This reservation was already cancelled. No charge was made."
            ))

        offering_raw = token_item.get("offeringDetails", "{}")
        offering     = json.loads(offering_raw) if offering_raw else {}
        region       = offering.get("Region",           "N/A")
        az           = offering.get("Availability Zone", "N/A")
        fee          = offering.get("Upfront Fee",       "N/A")

        if decision == "confirm":
            update_token_status("final-token-", token, "confirmed")

            # Write all offering fields to SSM so reserve.sh can read them
            put_param("offering-id",      offering.get("CapacityBlockOfferingId", ""))
            put_param("region",           offering.get("Region",           ""))
            put_param("az",               offering.get("Availability Zone", ""))
            put_param("instance-type",    offering.get("Instance Type",     ""))
            put_param("instance-count",   offering.get("Instance Count",    ""))
            put_param("upfront-fee",      offering.get("Upfront Fee",       ""))
            put_param("start-date",       offering.get("Start Date",        ""))
            put_param("end-date",         offering.get("End Date",          ""))
            put_param("selected-offering", json.dumps(offering, default=str))
            # Signal Step Functions that purchase is confirmed
            put_param("approval-decision", "confirmed")

            return html_response(HTML_OK.format(
                title="Purchase Confirmed",
                message=(
                    f"Your Capacity Block reservation for "
                    f"{region} / {az} ({fee}) is being purchased now. "
                    f"You will receive a pipeline completion email when "
                    f"the cluster is live and all instances have passed "
                    f"health checks."
                )
            ))

        if decision == "cancel":
            update_token_status("final-token-", token, "cancelled")
            put_param("approval-decision", "cancelled")
            invoke_cleanup("user_cancel")
            return html_response(HTML_OK.format(
                title="Purchase Cancelled",
                message=(
                    "The reservation has been cancelled. No charges were "
                    "made. All temporary watcher services will be deleted "
                    "shortly. Your permanent infrastructure has not been "
                    "touched."
                )
            ))

    # ════════════════════════════════════════════════════════════
    # Fallback
    # ════════════════════════════════════════════════════════════
    return html_response(HTML_ALREADY.format(
        title="Unknown Action",
        message=(
            "This link contained an unrecognised action. "
            "Please contact your AWS administrator."
        )
    ), 400)