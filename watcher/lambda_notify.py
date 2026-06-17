"""
lambda_notify.py — GPU Watcher Notification Lambda  (updated)

CHANGES FROM ORIGINAL:
  - Removed send_capacity_found_emails() — multi-AZ per-token system
  - Added send_capacity_found_email()   — single email, single PROCEED link
  - Final confirmation email unchanged
  - Timeout email unchanged
  - Heartbeat, pipeline started, retry started emails unchanged
"""

import os
import json
import uuid
import boto3
from datetime import datetime, timezone

AWS_REGION  = os.environ.get("AWS_REGION_NAME", "us-east-1")
SSM_PREFIX  = os.environ.get("SSM_PREFIX", "")
TABLE_NAME  = os.environ.get("TABLE_NAME", "")
PIPELINE_ID = os.environ.get("PIPELINE_RUN_ID", "")

ssm    = boto3.client("ssm",       region_name=AWS_REGION)
sns    = boto3.client("sns",       region_name=AWS_REGION)
dynamo = boto3.resource("dynamodb", region_name=AWS_REGION)

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

def publish_email(sns_arn: str, subject: str, body: str) -> None:
    sns.publish(TopicArn=sns_arn, Subject=subject, Message=body)

def approval_url(api_url: str, token: str, decision: str) -> str:
    return (f"{api_url}/approve"
            f"?token={token}&decision={decision}&pid={PIPELINE_ID}")

def fmt_now() -> str:
    return datetime.now(timezone.utc).strftime("%d %B %Y, %I:%M %p UTC")

# ---------------------------------------------------------------------------
# NEW — single capacity found email with one PROCEED link
# ---------------------------------------------------------------------------

def send_capacity_found_email(offerings: list, sns_arn: str,
                               api_url: str, pipeline_run_id: str) -> None:
    """
    Send ONE email listing all found offerings.
    Contains a single PROCEED TO CONFIRM link — no YES/WAIT/NO per AZ.
    If user ignores the email the scan continues automatically.
    """
    # Use the first (best) offering as the primary
    offering    = offerings[0]
    total_found = len(offerings)

    region      = offering.get("Region",           "N/A")
    az          = offering.get("Availability Zone", "N/A")
    itype       = offering.get("Instance Type",     "N/A")
    icount      = offering.get("Instance Count",    "N/A")
    start_date  = offering.get("Start Date",        "N/A")
    end_date    = offering.get("End Date",          "N/A")
    duration    = offering.get("Duration (days)",   "N/A")
    upfront_fee = offering.get("Upfront Fee",       "N/A")

    # Generate a single proceed token
    proceed_token = str(uuid.uuid4())[:16]

    # Save token + offering to DynamoDB
    get_table().put_item(Item={
        "pk":             f"proceed-token-{proceed_token}",
        "token":          proceed_token,
        "type":           "proceed",
        "offeringDetails": json.dumps(offering, default=str),
        "allOfferings":   json.dumps(offerings, default=str),
        "status":         "pending",
        "createdAt":      datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pipelineRunId":  pipeline_run_id
    })

    # Save token to SSM so approve Lambda can validate it
    put_param("proceed-token", proceed_token)

    proceed_url = approval_url(api_url, proceed_token, "proceed")

    # Build additional offerings block if more than one found
    other_lines = ""
    if total_found > 1:
        other_lines = (
            "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            "  OTHER AVAILABLE OFFERINGS\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        )
        for i, o in enumerate(offerings[1:], 2):
            other_lines += (
                f"  Offering {i}\n"
                f"  Instance Type          :   {o.get('Instance Type','N/A')}\n"
                f"  Region / AZ            :   {o.get('Region','N/A')} / "
                f"{o.get('Availability Zone','N/A')}\n"
                f"  Start Date             :   {o.get('Start Date','N/A')}\n"
                f"  End Date               :   {o.get('End Date','N/A')}\n"
                f"  Upfront Fee            :   {o.get('Upfront Fee','N/A')}\n\n"
            )
        other_lines += (
            "  Clicking PROCEED will use Offering 1 above.\n"
            "  To choose a different offering, contact your\n"
            "  AWS administrator before clicking PROCEED.\n"
        )

    subject = (f"[Action Required] AWS GPU Capacity Found — "
               f"{itype} in {az} — {upfront_fee}")

    body = f"""Dear Team,

This is an automated notification from your AWS GPU Capacity Block
Reservation Pipeline.

Capacity has been found matching your requested configuration.
Please review the details below carefully.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CAPACITY FOUND — OFFERING 1 (RECOMMENDED)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Instance Type          :   {itype}
  Instance Count         :   {icount}
  Region                 :   {region}
  Availability Zone      :   {az}
  Start Date and Time    :   {start_date}
  End Date and Time      :   {end_date}
  Duration               :   {duration} days
  Upfront Fee            :   {upfront_fee}

{other_lines}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ACTION REQUIRED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Do you want to proceed with this reservation?

  If YES — click the link below. You will receive
  a final confirmation email where you must confirm
  one more time before any purchase is made.
  Clicking this link does NOT charge your account.

  PROCEED TO CONFIRMATION:
  {proceed_url}

  If NO — simply ignore this email. The watcher
  will continue scanning for the next available
  slot every 15 minutes. You will receive a new
  email when capacity is found again.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  IMPORTANT NOTES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • Clicking PROCEED does NOT charge your account.
    A second confirmation email will be sent with
    a CONFIRM PURCHASE button — that is the only
    step that spends money.

  • If you ignore this email, the watcher continues
    searching automatically. No action needed to
    keep the pipeline running.

  • This PROCEED link expires in 4 hours from:
    {fmt_now()}

  • Capacity Blocks are limited. This slot may not
    be available by the time you respond.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PIPELINE CONTROLS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Stop the pipeline (watcher services deleted,
  permanent infrastructure kept):
  {approval_url(api_url, f"ctrl-{pipeline_run_id}", "stop")}

  Stop and delete all resources:
  {approval_url(api_url, f"ctrl-{pipeline_run_id}", "stop_terminate")}

  Restart with fresh 48-hour window:
  {approval_url(api_url, f"ctrl-{pipeline_run_id}", "restart")}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PIPELINE INFORMATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Pipeline Run ID        :   {pipeline_run_id}
  Email sent at          :   {fmt_now()}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This is an automated message. Do not reply to this email.
For questions contact your AWS administrator.

AWS GPU Capacity Block Reservation Pipeline
Powered by AWS Step Functions · Lambda · EventBridge
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"""

    publish_email(sns_arn, subject, body)
    print(f"[lambda_notify] Capacity found email sent — "
          f"{total_found} offering(s), primary: {region}/{az}")

# ---------------------------------------------------------------------------
# Final confirmation email — unchanged from original
# ---------------------------------------------------------------------------

def send_final_confirmation_email(offering: dict, proceed_token: str,
                                   sns_arn: str, api_url: str,
                                   pipeline_run_id: str) -> None:
    region      = offering.get("Region",           "N/A")
    az          = offering.get("Availability Zone", "N/A")
    itype       = offering.get("Instance Type",     "N/A")
    icount      = offering.get("Instance Count",    "N/A")
    start_date  = offering.get("Start Date",        "N/A")
    end_date    = offering.get("End Date",          "N/A")
    duration    = offering.get("Duration (days)",   "N/A")
    upfront_fee = offering.get("Upfront Fee",       "N/A")

    confirm_token = f"final-{str(uuid.uuid4())[:12]}"
    get_table().put_item(Item={
        "pk":             f"final-token-{confirm_token}",
        "token":          confirm_token,
        "type":           "final_confirmation",
        "offeringDetails": json.dumps(offering, default=str),
        "proceedToken":   proceed_token,
        "status":         "pending",
        "createdAt":      datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pipelineRunId":  pipeline_run_id
    })
    put_param("final-confirm-token", confirm_token)

    confirm_url = approval_url(api_url, confirm_token, "confirm")
    cancel_url  = approval_url(api_url, confirm_token, "cancel")

    subject = (f"[FINAL CONFIRMATION] AWS GPU Capacity Block — "
               f"{region} / {az} — {upfront_fee}")

    body = f"""Dear Team,

You clicked PROCEED. This is your FINAL CONFIRMATION REQUEST.
You are one step away from purchasing this Capacity Block.

Please read all details carefully. Once confirmed the reservation
is purchased immediately and the upfront fee is charged to your
AWS account. This cannot be undone.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  FINAL RESERVATION DETAILS — PLEASE VERIFY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Instance Type          :   {itype}
  Instance Count         :   {icount}
  Region                 :   {region}
  Availability Zone      :   {az}
  Start Date and Time    :   {start_date}
  End Date and Time      :   {end_date}
  Duration               :   {duration} days
  Upfront Fee            :   {upfront_fee}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  WARNING — READ BEFORE CONFIRMING
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • Clicking CONFIRM PURCHASE will immediately and
    irrevocably charge {upfront_fee} to your AWS account.

  • Capacity Blocks cannot be cancelled once purchased.
    There are no refunds under any circumstances.

  • Verify the instance type, count, region, AZ and
    dates above match what your team requires.

  • This confirmation link expires in 30 minutes from:
    {fmt_now()}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  YOUR FINAL DECISION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  CONFIRM PURCHASE — {upfront_fee}
  I have verified all details. I authorise the
  immediate purchase of this Capacity Block.
  {confirm_url}


  CANCEL — DO NOT PURCHASE
  Cancel this reservation. No charge will be made.
  All temporary watcher services will be deleted.
  {cancel_url}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PIPELINE INFORMATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Pipeline Run ID        :   {pipeline_run_id}
  Email sent at          :   {fmt_now()}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This is an automated message. Do not reply to this email.
For questions contact your AWS administrator.

AWS GPU Capacity Block Reservation Pipeline — FINAL CONFIRMATION
Powered by AWS Step Functions · Lambda · EventBridge
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"""

    publish_email(sns_arn, subject, body)
    print(f"[lambda_notify] Final confirmation email sent for {region}/{az}")

# ---------------------------------------------------------------------------
# Timeout email — unchanged from original
# ---------------------------------------------------------------------------

def send_timeout_email(sns_arn: str, api_url: str,
                        pipeline_run_id: str, attempts: int,
                        combinations: list) -> None:
    retry_url = approval_url(api_url,
                             f"timeout-{pipeline_run_id}", "retry")
    quit_url  = approval_url(api_url,
                             f"timeout-{pipeline_run_id}", "quit")

    combo_lines = ""
    for i, c in enumerate(combinations, 1):
        combo_lines += (
            f"  {i}.  Instance Type : {c.get('instance_type','N/A')}  |  "
            f"Region : {c.get('region','N/A')}  |  "
            f"AZ : {c.get('az','N/A')}\n"
            f"      Result        : No availability found\n\n"
        )

    subject = ("[Action Required] AWS GPU Capacity — "
               "No Availability Found After 48 Hours")

    body = f"""Dear Team,

This is an automated notification from your AWS GPU Capacity Block
Reservation Pipeline.

The 48-hour search window has elapsed without finding any available
Capacity Block matching your requested configuration.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SEARCH SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Total Attempts Made    :   {attempts}
  Search Duration        :   48 hours
  Search Ended           :   {fmt_now()}
  Combinations Searched  :   {len(combinations)}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CONFIGURATIONS SEARCHED — NO AVAILABILITY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{combo_lines}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ACTION REQUIRED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  This link expires in 4 hours from: {fmt_now()}

  RETRY — SEARCH AGAIN FOR ANOTHER 48 HOURS
  A fresh search window begins immediately using
  the same configuration. Attempt counter resets.
  {retry_url}


  QUIT — STOP AND CLEAN UP
  All temporary AWS watcher services will be
  deleted. Permanent infrastructure is kept.
  No charges will be incurred.
  {quit_url}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PIPELINE INFORMATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Pipeline Run ID        :   {pipeline_run_id}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This is an automated message. Do not reply to this email.

AWS GPU Capacity Block Reservation Pipeline
Powered by AWS Step Functions · Lambda · EventBridge
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"""

    publish_email(sns_arn, subject, body)
    print(f"[lambda_notify] 48-hour timeout email sent")

# ---------------------------------------------------------------------------
# Pipeline started email
# ---------------------------------------------------------------------------

def send_pipeline_started_email(sns_arn: str, pipeline_run_id: str,
                                 combinations: list, instance_count: str,
                                 duration_days: str, max_hours: str,
                                 retry_mins: str) -> None:
    combo_lines = ""
    for i, c in enumerate(combinations, 1):
        combo_lines += (f"  {i}.  {c.get('instance_type','N/A')}  |  "
                        f"{c.get('region','N/A')}  |  "
                        f"{c.get('az','N/A')}\n")

    subject = (f"[Started] AWS GPU Capacity Block Pipeline — "
               f"{pipeline_run_id}")

    body = f"""Dear Team,

Your AWS GPU Capacity Block Reservation Pipeline has started
successfully and is now running in AWS.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PIPELINE DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Pipeline Run ID        :   {pipeline_run_id}
  Started At             :   {fmt_now()}
  Instance Count         :   {instance_count}
  Duration               :   {duration_days} days
  Scan Interval          :   Every {retry_mins} minutes
  Max Search Window      :   {max_hours} hours

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  COMBINATIONS BEING SEARCHED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{combo_lines}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  WHAT HAPPENS NEXT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  The watcher scans every {retry_mins} minutes for up to {max_hours} hours.

  When capacity is found you receive ONE email with
  a PROCEED TO CONFIRMATION link. Clicking PROCEED
  sends a final confirmation email. CONFIRM PURCHASE
  in that email is the only step that spends money.

  If you ignore a capacity found email the watcher
  continues scanning automatically.

  You also receive a heartbeat email after every
  scan attempt so you can track progress.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This is an automated message. Do not reply to this email.

AWS GPU Capacity Block Reservation Pipeline
Powered by AWS Step Functions · Lambda · EventBridge
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"""

    sns.publish(TopicArn=sns_arn, Subject=subject, Message=body)
    print(f"[lambda_notify] Pipeline started email sent")

# ---------------------------------------------------------------------------
# Heartbeat email
# ---------------------------------------------------------------------------

def send_scan_heartbeat_email(sns_arn: str, pipeline_run_id: str,
                               attempt: int, max_attempts: int,
                               combinations: list, errors: list,
                               api_url: str) -> None:
    mins_done  = attempt * 15
    hours_done = mins_done // 60
    mins_left  = (max_attempts - attempt) * 15
    hours_left = mins_left // 60
    mins_left_r = mins_left % 60
    pct        = round(attempt / max_attempts * 100, 1)

    combo_lines = ""
    for c in combinations:
        combo_lines += (f"  {c.get('instance_type','N/A')}  |  "
                        f"{c.get('region','N/A')}  |  "
                        f"{c.get('az','N/A')}  →  No availability\n")

    error_section = ""
    if errors:
        error_section = ("\n  Note: Some regions returned API errors "
                         "(normal for unsupported instance types)\n")
        for e in errors[:3]:
            error_section += (f"  {e.get('Region','?')}  :  "
                              f"{e.get('Error','?')}\n")

    subject = (f"[Scan {attempt}/{max_attempts}] "
               f"No capacity found yet — {pct}% complete")

    body = f"""Dear Team,

Scan {attempt} of {max_attempts} completed. No GPU capacity found yet.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SCAN PROGRESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Attempt                :   {attempt} of {max_attempts}
  Progress               :   {pct}%
  Time elapsed           :   ~{hours_done}h {mins_done % 60}m
  Time remaining         :   ~{hours_left}h {mins_left_r}m
  Scanned at             :   {fmt_now()}
  Pipeline Run ID        :   {pipeline_run_id}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  RESULT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{combo_lines}{error_section}
  Next scan in 15 minutes. No action needed.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PIPELINE CONTROLS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Stop the pipeline (watcher services deleted,
  permanent infrastructure kept):
  {approval_url(api_url, f"ctrl-{pipeline_run_id}", "stop")}

  Stop and delete all resources:
  {approval_url(api_url, f"ctrl-{pipeline_run_id}", "stop_terminate")}

  Restart with fresh 48-hour window:
  {approval_url(api_url, f"ctrl-{pipeline_run_id}", "restart")}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This is an automated message. Do not reply to this email.

AWS GPU Capacity Block Reservation Pipeline
Powered by AWS Step Functions · Lambda · EventBridge
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"""

    sns.publish(TopicArn=sns_arn, Subject=subject, Message=body)
    print(f"[lambda_notify] Heartbeat email sent — "
          f"attempt {attempt}/{max_attempts}")

# ---------------------------------------------------------------------------
# Retry started email
# ---------------------------------------------------------------------------

def send_retry_started_email(sns_arn: str, pipeline_run_id: str,
                              combinations: list, max_hours: str,
                              retry_mins: str) -> None:
    combo_lines = ""
    for i, c in enumerate(combinations, 1):
        combo_lines += (f"  {i}.  {c.get('instance_type','N/A')}  |  "
                        f"{c.get('region','N/A')}  |  "
                        f"{c.get('az','N/A')}\n")

    subject = ("[Retrying] AWS GPU Capacity Search — "
               "Fresh 48-Hour Window Started")

    body = f"""Dear Team,

You clicked RETRY. A fresh 48-hour search window has started.
The attempt counter has been reset to zero.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  RETRY DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Pipeline Run ID        :   {pipeline_run_id}
  Retry Started At       :   {fmt_now()}
  New Search Window      :   {max_hours} hours
  Scan Interval          :   Every {retry_mins} minutes

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  COMBINATIONS BEING SEARCHED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{combo_lines}
  You will be notified when capacity is found
  or when the new 48-hour window expires.

This is an automated message. Do not reply to this email.

AWS GPU Capacity Block Reservation Pipeline
Powered by AWS Step Functions · Lambda · EventBridge
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"""

    sns.publish(TopicArn=sns_arn, Subject=subject, Message=body)
    print(f"[lambda_notify] Retry started email sent")

# ---------------------------------------------------------------------------
# Main handler
# ---------------------------------------------------------------------------

def handler(event: dict, context) -> dict:
    action          = event.get("action", "notify_found")
    pipeline_run_id = event.get("pipelineRunId", PIPELINE_ID)
    print(f"[lambda_notify] action={action}")

    sns_arn = get_param("sns-topic-arn")
    api_url = get_param("api-gateway-url")

    if not sns_arn:
        print("[lambda_notify] No SNS ARN — cannot send email")
        return {"sent": False, "error": "No SNS ARN"}

    # ── notify_found: NEW single capacity found email ─────────────────────────
    if action == "notify_found":
        offerings_raw = get_param("found-offerings")
        offerings     = json.loads(offerings_raw) if offerings_raw else []
        if not offerings:
            return {"sent": False, "error": "No offerings to notify"}
        send_capacity_found_email(offerings, sns_arn, api_url, pipeline_run_id)
        return {"sent": True, "emailCount": 1, "offeringsFound": len(offerings)}

    # ── send_final_confirmation ───────────────────────────────────────────────
    if action == "send_final_confirmation":
        proceed_token = event.get("token", get_param("proceed-token"))
        offering_raw  = get_param("selected-offering")
        offering      = json.loads(offering_raw) if offering_raw else {}
        if not offering:
            return {"sent": False, "error": "No selected offering"}
        send_final_confirmation_email(
            offering, proceed_token, sns_arn, api_url, pipeline_run_id
        )
        return {"sent": True}

    # ── notify_timeout ────────────────────────────────────────────────────────
    if action == "notify_timeout":
        state     = get_table().get_item(
            Key={"pk": "watcher-state"}
        ).get("Item", {})
        attempts  = int(state.get("attemptCount", 0))
        combo_str = get_param("combinations")
        combos    = [
            {"instance_type": p.split("|")[0],
             "region":        p.split("|")[1],
             "az":            p.split("|")[2]}
            for p in combo_str.split(";") if "|" in p
        ]
        send_timeout_email(
            sns_arn, api_url, pipeline_run_id, attempts, combos
        )
        return {"sent": True}

    # ── notify_error ──────────────────────────────────────────────────────────
    if action == "notify_error":
        error_msg = event.get("error", "Unknown error")
        sns.publish(
            TopicArn=sns_arn,
            Subject=(f"[ERROR] AWS GPU Capacity Pipeline Failed — "
                     f"{pipeline_run_id}"),
            Message=(f"Pipeline {pipeline_run_id} encountered an error:\n\n"
                     f"{error_msg}\n\nCheck CloudWatch logs for details.")
        )
        return {"sent": True}

    # ── pipeline_started ──────────────────────────────────────────────────────
    if action == "pipeline_started":
        combo_str = get_param("combinations")
        combos    = [
            {"instance_type": p.split("|")[0],
             "region":        p.split("|")[1],
             "az":            p.split("|")[2]}
            for p in combo_str.split(";") if "|" in p
        ]
        send_pipeline_started_email(
            sns_arn, pipeline_run_id, combos,
            get_param("instance-count"),
            get_param("duration-days"),
            get_param("max-hours"),
            get_param("retry-mins"),
        )
        return {"sent": True}

    # ── scan_heartbeat ────────────────────────────────────────────────────────
    if action == "scan_heartbeat":
        attempt      = int(event.get("attempt", 0))
        max_attempts = int(event.get("maxAttempts", 192))
        errors       = event.get("errors", [])
        combo_str    = get_param("combinations")
        combos       = [
            {"instance_type": p.split("|")[0],
             "region":        p.split("|")[1],
             "az":            p.split("|")[2]}
            for p in combo_str.split(";") if "|" in p
        ]
        send_scan_heartbeat_email(
            sns_arn, pipeline_run_id,
            attempt, max_attempts, combos, errors, api_url
        )
        return {"sent": True}

    # ── notify_retry_started ──────────────────────────────────────────────────
    if action == "notify_retry_started":
        combo_str = get_param("combinations")
        combos    = [
            {"instance_type": p.split("|")[0],
             "region":        p.split("|")[1],
             "az":            p.split("|")[2]}
            for p in combo_str.split(";") if "|" in p
        ]
        send_retry_started_email(
            sns_arn, pipeline_run_id, combos,
            get_param("max-hours"),
            get_param("retry-mins"),
        )
        return {"sent": True}

    return {"sent": False, "error": f"Unknown action: {action}"}