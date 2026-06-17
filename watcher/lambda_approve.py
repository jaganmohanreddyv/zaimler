"""
lambda_approve.py — GPU Watcher Approval Handler (multi-AZ)

MULTI-AZ FLOW:
  PROCEED on AZ-N email:
    → mark token as 'used'
    → mark all other AZ tokens as 'invalidated'
    → send cancellation follow-up email for each invalidated AZ
    → write selected offering to SSM
    → set approval-decision = 'proceed'
    → trigger final confirmation email

  REJECT on AZ-N email:
    → mark token as 'declined'
    → if other AZ tokens still 'pending' → those emails remain valid
    → if ALL AZ tokens are 'declined'/'invalidated':
        → send all-AZ-rejected email
        → set approval-decision = 'all_rejected'
        → trigger cleanup (pipeline stops)

  CONFIRM final confirmation:
    → set approval-decision = 'confirmed'

  CANCEL final confirmation:
    → set approval-decision = 'cancelled'
    → trigger cleanup
"""

import os, json, boto3
from datetime import datetime

AWS_REGION  = os.environ.get("AWS_REGION_NAME", "us-east-1")
SSM_PREFIX  = os.environ.get("SSM_PREFIX", "")
TABLE_NAME  = os.environ.get("TABLE_NAME", "")
PIPELINE_ID = os.environ.get("PIPELINE_RUN_ID", "")

ssm    = boto3.client("ssm",        region_name=AWS_REGION)
dynamo = boto3.resource("dynamodb", region_name=AWS_REGION)
lmb    = boto3.client("lambda",     region_name=AWS_REGION)

# ── HTML pages ────────────────────────────────────────────────────────────────
def _page(bg, title_color, icon, title, message):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "text/html"},
        "body": f"""<!DOCTYPE html><html>
<body style="font-family:Arial,sans-serif;max-width:600px;margin:60px auto;text-align:center;">
<div style="background:{bg};border-radius:12px;padding:40px;">
<h2 style="color:{title_color};">{icon} {title}</h2>
<p style="color:#555;">{message}</p>
<p style="color:#888;font-size:12px;margin-top:30px;">
  Automated message — AWS GPU Capacity Block Reservation Pipeline.</p>
</div></body></html>"""
    }

def page_ok(title, msg):
    return _page("#e8f5e9", "#2e7d32", "&#10003;", title, msg)

def page_warn(title, msg):
    return _page("#fff3e0", "#e65100", "&#8505;", title, msg)

def page_err(title, msg):
    return _page("#fce4ec", "#c62828", "&#8855;", title, msg)

def page_info(title, msg):
    return _page("#fff8e1", "#f57f17", "&#9888;", title, msg)

EXPIRED = page_err("Link Expired",
    "This link has expired or is no longer valid. "
    "Please check your inbox for a newer email.")

# ── helpers ───────────────────────────────────────────────────────────────────
def get_param(key):
    try:
        return ssm.get_parameter(Name=f"{SSM_PREFIX}/{key}")["Parameter"]["Value"]
    except Exception:
        return ""

def put_param(key, value):
    try:
        ssm.put_parameter(Name=f"{SSM_PREFIX}/{key}", Value=value,
                          Type="String", Overwrite=True)
    except Exception as e:
        print(f"[WARN] SSM put {key}: {e}")

def get_table():
    return dynamo.Table(TABLE_NAME)

def get_az_token(token):
    try:
        return get_table().get_item(
            Key={"pk": f"proceed-token-{token}"}
        ).get("Item", {})
    except Exception:
        return {}

def set_az_token_status(token, status):
    try:
        get_table().update_item(
            Key={"pk": f"proceed-token-{token}"},
            UpdateExpression="SET #s=:s, updatedAt=:t",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":s": status,
                ":t": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
            }
        )
    except Exception as e:
        print(f"[WARN] set_az_token_status {token}: {e}")

def get_final_token(token):
    try:
        return get_table().get_item(
            Key={"pk": f"final-token-{token}"}
        ).get("Item", {})
    except Exception:
        return {}

def set_final_token_status(token, status):
    try:
        get_table().update_item(
            Key={"pk": f"final-token-{token}"},
            UpdateExpression="SET #s=:s",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": status}
        )
    except Exception as e:
        print(f"[WARN] set_final_token_status {token}: {e}")

def invoke_notify(action, extra=None):
    try:
        payload = {"action": action, "pipelineRunId": PIPELINE_ID}
        if extra:
            payload.update(extra)
        lmb.invoke(
            FunctionName=f"gpu-watcher-notify-{PIPELINE_ID}",
            InvocationType="Event",
            Payload=json.dumps(payload).encode(),
        )
        print(f"[lambda_approve] invoked notify:{action}")
    except Exception as e:
        print(f"[WARN] invoke_notify {action}: {e}")

def invoke_cleanup(reason):
    try:
        lmb.invoke(
            FunctionName=f"gpu-watcher-cleanup-{PIPELINE_ID}",
            InvocationType="Event",
            Payload=json.dumps({
                "pipelineRunId": PIPELINE_ID, "reason": reason
            }).encode(),
        )
        print(f"[lambda_approve] cleanup triggered: {reason}")
    except Exception as e:
        print(f"[WARN] invoke_cleanup: {e}")

def invoke_infra_cleanup():
    try:
        lmb.invoke(
            FunctionName=f"gpu-watcher-infra-cleanup-{PIPELINE_ID}",
            InvocationType="Event",
            Payload=json.dumps({
                "pipelineRunId": PIPELINE_ID, "reason": "user_stop_terminate"
            }).encode(),
        )
    except Exception as e:
        print(f"[WARN] invoke_infra_cleanup: {e}")

# ── main handler ──────────────────────────────────────────────────────────────
def handler(event, context):
    params          = event.get("queryStringParameters") or {}
    token           = params.get("token",    "")
    decision        = params.get("decision", "").lower()
    pipeline_run_id = params.get("pid",      PIPELINE_ID)

    print(f"[lambda_approve] token={token[:12] if token else ''!r} decision={decision}")

    if not token or not decision:
        return page_err("Invalid Request",
                        "This link is missing required parameters.")

    # ── pipeline controls ─────────────────────────────────────────────────────
    if token.startswith("ctrl-"):
        existing = get_param("control-decision")
        if existing in ("stop", "stop_terminate", "restart"):
            return page_warn("Already Actioned",
                f"Control action '{existing}' was already applied.")
        if decision == "stop":
            put_param("control-decision", "stop")
            invoke_cleanup("user_stop")
            return page_ok("Pipeline Stopped",
                "All temporary watcher services will be deleted shortly. "
                "Permanent infrastructure is untouched. No purchase was made.")
        if decision == "stop_terminate":
            put_param("control-decision", "stop_terminate")
            invoke_cleanup("user_stop_terminate")
            invoke_infra_cleanup()
            return page_info("Stopping — All Resources Being Deleted",
                "The watcher has stopped and ALL resources are being deleted "
                "including permanent infrastructure. Run bash main.sh to restart.")
        if decision == "restart":
            put_param("control-decision", "restart")
            put_param("retry-quit-decision", "retry")
            return page_ok("Pipeline Restarting",
                "A fresh 48-hour search window will begin immediately.")
        return page_err("Unknown Control",
                        f"Unrecognised control decision: {decision}")

    # ── timeout retry / quit ──────────────────────────────────────────────────
    if token.startswith("timeout-"):
        if decision == "retry":
            put_param("retry-quit-decision", "retry")
            return page_ok("Retry Confirmed",
                "A fresh 48-hour search window has started.")
        if decision == "quit":
            put_param("retry-quit-decision", "quit")
            invoke_cleanup("user_quit")
            return page_ok("Pipeline Stopped",
                "All temporary watcher services will be deleted shortly.")
        return EXPIRED

    # ── final confirmation ────────────────────────────────────────────────────
    if token.startswith("final-"):
        item   = get_final_token(token)
        if not item:
            return EXPIRED
        status = item.get("status", "")
        if status == "confirmed":
            return page_warn("Already Confirmed",
                "This reservation is already being processed.")
        if status == "cancelled":
            return page_warn("Already Cancelled",
                "This reservation was already cancelled. No charge was made.")

        offering = json.loads(item.get("offeringDetails", "{}"))
        region   = offering.get("Region",            "N/A")
        az       = offering.get("Availability Zone",  "N/A")
        fee      = offering.get("Upfront Fee",        "N/A")

        if decision == "confirm":
            set_final_token_status(token, "confirmed")
            put_param("offering-id",       offering.get("CapacityBlockOfferingId", ""))
            put_param("region",            offering.get("Region",           ""))
            put_param("az",                offering.get("Availability Zone", ""))
            put_param("instance-type",     offering.get("Instance Type",     ""))
            put_param("instance-count",    offering.get("Instance Count",    ""))
            put_param("upfront-fee",       offering.get("Upfront Fee",       ""))
            put_param("start-date",        offering.get("Start Date",        ""))
            put_param("end-date",          offering.get("End Date",          ""))
            put_param("selected-offering", json.dumps(offering, default=str))
            put_param("approval-decision", "confirmed")
            return page_ok("Purchase Confirmed",
                f"Your Capacity Block for {region} / {az} ({fee}) "
                f"is being purchased now. A completion email will be sent "
                f"when the cluster is live.")

        if decision == "cancel":
            set_final_token_status(token, "cancelled")
            put_param("approval-decision", "cancelled")
            invoke_cleanup("user_cancel")
            return page_ok("Purchase Cancelled",
                "No charges were made. All temporary watcher services "
                "will be deleted shortly.")

        return EXPIRED

    # ── per-AZ PROCEED ────────────────────────────────────────────────────────
    if decision == "proceed":
        item   = get_az_token(token)
        if not item:
            return EXPIRED
        status = item.get("status", "")

        if status == "invalidated":
            return page_warn("This AZ Is No Longer Available",
                "Another AZ was already selected. This option has been cancelled.")
        if status == "used":
            return page_warn("Already Proceeded",
                "You already clicked PROCEED for this AZ. "
                "Check your inbox for the final confirmation email.")
        if status == "declined":
            return page_warn("Already Rejected",
                "You already rejected this AZ.")

        # Mark this token used
        set_az_token_status(token, "used")

        chosen_offering = json.loads(item.get("offeringDetails", "{}"))
        all_tokens      = item.get("allTokens", [])

        # Invalidate all other AZ tokens and send cancellation emails
        for other_token in all_tokens:
            if other_token == token:
                continue
            other_item = get_az_token(other_token)
            other_status = other_item.get("status", "")
            if other_status == "pending":
                set_az_token_status(other_token, "invalidated")
                other_offering = json.loads(
                    other_item.get("offeringDetails", "{}"))
                # Send cancellation follow-up email for this AZ
                invoke_notify("send_az_cancelled", {
                    "cancelledOffering": other_offering,
                    "chosenOffering":    chosen_offering,
                })
                print(f"[lambda_approve] Sent cancellation for "
                      f"{other_offering.get('Availability Zone','?')}")

        # Write selected offering + signal Step Functions
        put_param("selected-offering", json.dumps(chosen_offering, default=str))
        put_param("proceed-token",     token)
        put_param("approval-decision", "proceed")

        # Trigger final confirmation email
        invoke_notify("send_final_confirmation", {"token": token})

        region = chosen_offering.get("Region",            "N/A")
        az     = chosen_offering.get("Availability Zone",  "N/A")
        fee    = chosen_offering.get("Upfront Fee",        "N/A")

        return page_ok(
            f"AZ Selected — Final Confirmation Sent",
            f"You selected {region} / {az} ({fee}). "
            f"All other AZ emails have been cancelled and a cancellation "
            f"notice has been sent for each. "
            f"Check your inbox for the final confirmation email. "
            f"Clicking CONFIRM PURCHASE in that email is the only step "
            f"that charges your account."
        )

    # ── per-AZ REJECT ─────────────────────────────────────────────────────────
    if decision == "reject":
        item   = get_az_token(token)
        if not item:
            return EXPIRED
        status = item.get("status", "")

        if status == "invalidated":
            return page_warn("This AZ Is No Longer Available",
                "Another AZ was already selected. This option has been cancelled.")
        if status in ("declined", "used"):
            return page_warn("Already Responded",
                f"You have already responded to this AZ ({status}).")

        # Mark this token as declined
        set_az_token_status(token, "declined")

        offering = json.loads(item.get("offeringDetails", "{}"))
        region   = offering.get("Region",            "N/A")
        az       = offering.get("Availability Zone",  "N/A")
        all_tokens = item.get("allTokens", [])

        # Check if any tokens are still pending
        pending_tokens = []
        for t in all_tokens:
            if t == token:
                continue
            other_item   = get_az_token(t)
            other_status = other_item.get("status", "")
            if other_status == "pending":
                pending_tokens.append(t)

        if pending_tokens:
            # Other AZ emails still active — user can act on them
            return page_ok(
                f"AZ Declined — {len(pending_tokens)} Other AZ Email(s) Active",
                f"You rejected {region} / {az}. "
                f"You have {len(pending_tokens)} other AZ email(s) still active "
                f"in your inbox. Click PROCEED on one of them to select it, "
                f"or REJECT to decline it too."
            )
        else:
            # ALL AZ tokens are now declined or invalidated
            # Send all-AZ-rejected email and stop the pipeline
            invoke_notify("send_all_az_rejected")
            put_param("approval-decision", "all_rejected")
            invoke_cleanup("user_rejected_all_az")

            return page_ok(
                "All AZs Declined — Pipeline Stopping",
                f"You rejected {region} / {az}. "
                f"All available AZ options have now been declined. "
                f"The pipeline is stopping and all temporary watcher "
                f"services will be deleted. You will receive a "
                f"notification email confirming the pipeline has stopped. "
                f"Run bash main.sh to start a new search."
            )

    return page_err("Unknown Action",
                    "This link contained an unrecognised action.")