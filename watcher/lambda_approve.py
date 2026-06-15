"""
lambda_approve.py — GPU Watcher Approval Handler Lambda
Handles email link clicks: YES, NO, WAIT, CONFIRM, CANCEL, RETRY, QUIT
Called by API Gateway when user clicks a link in an approval email.
"""

import os
import json
import boto3
from datetime import datetime

AWS_REGION  = os.environ.get("AWS_REGION_NAME", "us-east-1")
SSM_PREFIX  = os.environ.get("SSM_PREFIX", "")
TABLE_NAME  = os.environ.get("TABLE_NAME", "")
PIPELINE_ID = os.environ.get("PIPELINE_RUN_ID", "")

ssm    = boto3.client("ssm",      region_name=AWS_REGION)
dynamo = boto3.resource("dynamodb", region_name=AWS_REGION)
sns    = boto3.client("sns",      region_name=AWS_REGION)
sfn    = boto3.client("stepfunctions", region_name=AWS_REGION)

HTML_OK = """<!DOCTYPE html><html><body style="font-family:Arial,sans-serif;max-width:600px;margin:60px auto;text-align:center;">
<div style="background:#e8f5e9;border-radius:12px;padding:40px;">
<h2 style="color:#2e7d32;">&#10003; {title}</h2>
<p style="color:#555;">{message}</p>
<p style="color:#888;font-size:12px;margin-top:30px;">This is an automated message from AWS GPU Capacity Block Reservation Pipeline.</p>
</div></body></html>"""

HTML_ALREADY = """<!DOCTYPE html><html><body style="font-family:Arial,sans-serif;max-width:600px;margin:60px auto;text-align:center;">
<div style="background:#fff3e0;border-radius:12px;padding:40px;">
<h2 style="color:#e65100;">&#8505; {title}</h2>
<p style="color:#555;">{message}</p>
</div></body></html>"""

HTML_EXPIRED = """<!DOCTYPE html><html><body style="font-family:Arial,sans-serif;max-width:600px;margin:60px auto;text-align:center;">
<div style="background:#fce4ec;border-radius:12px;padding:40px;">
<h2 style="color:#c62828;">&#8855; Link Expired</h2>
<p style="color:#555;">This approval link has expired. Please check your inbox for a reminder email, or contact your AWS administrator.</p>
</div></body></html>"""

def html_response(body: str, status: int = 200) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "text/html"},
        "body": body
    }

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

def get_token(token: str) -> dict:
    try:
        resp = get_table().get_item(Key={"pk": f"token-{token}"})
        return resp.get("Item", {})
    except Exception:
        return {}

def update_token_status(token: str, status: str) -> None:
    try:
        get_table().update_item(
            Key={"pk": f"token-{token}"},
            UpdateExpression="SET #s=:s, updatedAt=:t",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":s": status,
                ":t": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
            }
        )
    except Exception as e:
        print(f"[WARN] update_token_status: {e}")

def invalidate_all_other_tokens(approved_token: str) -> None:
    """Invalidate all other pending AZ tokens."""
    try:
        tokens_raw = get_param("approval-tokens")
        if not tokens_raw:
            return
        tokens = json.loads(tokens_raw)
        for t in tokens:
            if t != approved_token:
                update_token_status(t, "invalidated")
    except Exception as e:
        print(f"[WARN] invalidate_all_other_tokens: {e}")

def trigger_pipeline_resume(offering: dict, pipeline_run_id: str) -> None:
    """Write offering to SSM so reserve.sh can use it."""
    put_param("offering-id",      offering.get("CapacityBlockOfferingId", ""))
    put_param("region",           offering.get("Region", ""))
    put_param("az",               offering.get("Availability Zone", ""))
    put_param("instance-type",    offering.get("Instance Type", ""))
    put_param("instance-count",   offering.get("Instance Count", ""))
    put_param("upfront-fee",      offering.get("Upfront Fee", ""))
    put_param("start-date",       offering.get("Start Date", ""))
    put_param("end-date",         offering.get("End Date", ""))
    put_param("selected-offering", json.dumps(offering, default=str))
    put_param("approval-decision", "confirmed")

# ---------------------------------------------------------------------------
def handler(event: dict, context) -> dict:
    params        = event.get("queryStringParameters") or {}
    token         = params.get("token", "")
    decision      = params.get("decision", "").lower()
    pipeline_run_id = params.get("pid", PIPELINE_ID)

    print(f"[lambda_approve] token={token} decision={decision}")

    if not token or not decision:
        return html_response(
            HTML_ALREADY.format(
                title="Invalid Request",
                message="This link is missing required parameters."
            ), 400
        )

    # ── TIMEOUT RETRY / QUIT ─────────────────────────────────────────────────
    if token.startswith("timeout-"):
        if decision == "retry":
            put_param("retry-quit-decision", "retry")
            return html_response(HTML_OK.format(
                title="Retry Confirmed",
                message="A fresh 48-hour search window has started. You will receive an email when capacity becomes available."
            ))
        elif decision == "quit":
            put_param("retry-quit-decision", "quit")
            return html_response(HTML_OK.format(
                title="Pipeline Stopped",
                message="The pipeline has been stopped. All temporary AWS watcher services will be deleted shortly. No charges were incurred."
            ))

    # ── FINAL CONFIRMATION ───────────────────────────────────────────────────
    if token.startswith("final-"):
        token_item = get_table().get_item(
            Key={"pk": f"final-token-{token}"}
        ).get("Item", {})

        if not token_item:
            return html_response(HTML_EXPIRED)

        if token_item.get("status") == "confirmed":
            return html_response(HTML_ALREADY.format(
                title="Already Confirmed",
                message="This reservation has already been confirmed and is being processed."
            ))

        if token_item.get("status") == "cancelled":
            return html_response(HTML_ALREADY.format(
                title="Already Cancelled",
                message="This reservation was already cancelled."
            ))

        if decision == "confirm":
            # Update final token status
            get_table().update_item(
                Key={"pk": f"final-token-{token}"},
                UpdateExpression="SET #s=:s",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":s": "confirmed"}
            )
            # Load offering from token
            offering = json.loads(token_item.get("offeringDetails", "{}"))
            trigger_pipeline_resume(offering, pipeline_run_id)
            # Invalidate all AZ tokens
            original_token = token_item.get("originalToken", "")
            if original_token:
                invalidate_all_other_tokens(original_token)

            return html_response(HTML_OK.format(
                title="Purchase Confirmed",
                message=f"Your Capacity Block reservation for {offering.get('Region','N/A')} / {offering.get('Availability Zone','N/A')} is being processed. You will receive a confirmation email when the cluster is live."
            ))

        elif decision == "cancel":
            get_table().update_item(
                Key={"pk": f"final-token-{token}"},
                UpdateExpression="SET #s=:s",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":s": "cancelled"}
            )
            put_param("approval-decision", "cancelled")
            return html_response(HTML_OK.format(
                title="Purchase Cancelled",
                message="The reservation has been cancelled. No charges were made. All temporary watcher services will be cleaned up shortly."
            ))

    # ── AZ EMAIL APPROVAL (YES / NO / WAIT) ──────────────────────────────────
    token_item = get_token(token)

    if not token_item:
        return html_response(HTML_EXPIRED)

    current_status = token_item.get("status", "")

    if current_status == "invalidated":
        return html_response(HTML_ALREADY.format(
            title="This Link Is No Longer Valid",
            message="Another AZ has already been selected for reservation, or this option was previously declined. Please check your inbox for a final confirmation email or a pipeline status update."
        ))

    if current_status in ("approved", "declined", "skipped"):
        return html_response(HTML_ALREADY.format(
            title="Already Responded",
            message=f"You have already responded to this option with: {current_status}. No further action is needed."
        ))

    offering = json.loads(token_item.get("offeringDetails", "{}"))
    region = offering.get("Region", "N/A")
    az     = offering.get("Availability Zone", "N/A")

    if decision == "yes":
        # Mark this token as selected
        update_token_status(token, "selected")
        # Invalidate all other AZ tokens
        invalidate_all_other_tokens(token)
        # Store selected offering for notify Lambda
        put_param("selected-offering", json.dumps(offering, default=str))
        put_param("selected-token", token)
        # Trigger final confirmation email via SNS
        sns_arn = get_param("sns-topic-arn")
        api_url = get_param("api-gateway-url")
        if sns_arn and api_url:
            # Import and call notify lambda logic inline
            import importlib
            import sys
            notify_mod_path = os.path.join(os.path.dirname(__file__), "lambda_notify.py")
            if os.path.exists(notify_mod_path):
                spec = importlib.util.spec_from_file_location("lambda_notify", notify_mod_path)
                notify_mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(notify_mod)
                notify_mod.send_final_confirmation_email(
                    offering, token, sns_arn, api_url, pipeline_run_id
                )

        return html_response(HTML_OK.format(
            title="Selection Confirmed",
            message=f"You selected {region} / {az}. A final confirmation email has been sent to you. Please check your inbox and click CONFIRM PURCHASE to complete the reservation."
        ))

    elif decision == "no":
        update_token_status(token, "declined")
        # Check if all tokens are declined/skipped
        tokens_raw = get_param("approval-tokens")
        if tokens_raw:
            all_tokens = json.loads(tokens_raw)
            all_done = all(
                get_token(t).get("status", "") in ("declined", "skipped", "invalidated")
                for t in all_tokens if t != token
            )
            if all_done:
                put_param("approval-decision", "cancelled")

        return html_response(HTML_OK.format(
            title="AZ Declined",
            message=f"You have declined {region} / {az}. The watcher will continue searching your other configured combinations. You will receive another email if capacity becomes available."
        ))

    elif decision == "wait":
        update_token_status(token, "skipped")
        return html_response(HTML_OK.format(
            title="Skipped — Watching for Next Available",
            message=f"You have skipped {region} / {az}. This slot has been permanently skipped. The watcher is continuing to search your remaining configurations. Please note: we cannot guarantee another slot will become available within your remaining 48-hour window."
        ))

    return html_response(HTML_ALREADY.format(
        title="Unknown Action",
        message="This link contained an unrecognised action. Please contact your AWS administrator."
    ), 400)
