"""
lambda_notify.py — GPU Watcher Notification Lambda
Sends professional per-AZ emails for capacity found,
48-hour timeout, reminders, and pipeline errors.
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

ssm    = boto3.client("ssm",      region_name=AWS_REGION)
sns    = boto3.client("sns",      region_name=AWS_REGION)
dynamo = boto3.resource("dynamodb", region_name=AWS_REGION)

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
    return f"{api_url}/approve?token={token}&decision={decision}&pid={PIPELINE_ID}"

def fmt_now() -> str:
    return datetime.now(timezone.utc).strftime("%d %B %Y, %I:%M %p UTC")

# ---------------------------------------------------------------------------
def send_capacity_found_emails(offerings: list, sns_arn: str,
                                api_url: str, pipeline_run_id: str) -> None:
    """Send one separate email per AZ that has capacity."""
    total = len(offerings)
    tokens = {}

    # Build token map — one token per offering
    for i, offering in enumerate(offerings):
        token = str(uuid.uuid4())[:12]
        tokens[token] = {
            "index": i,
            "offeringDetails": offering,
            "status": "pending"
        }
        # Save token to DynamoDB
        get_table().put_item(Item={
            "pk": f"token-{token}",
            "token": token,
            "offeringIndex": i,
            "offeringDetails": json.dumps(offering, default=str),
            "status": "pending",
            "createdAt": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "pipelineRunId": pipeline_run_id
        })

    # Save all tokens to SSM
    put_param("approval-tokens", json.dumps(list(tokens.keys())))

    other_azs = []
    for offering in offerings:
        region = offering.get("Region", "")
        az     = offering.get("Availability Zone", "")
        other_azs.append(f"{region} / {az}")

    # Send one email per offering/AZ
    for idx, (token, token_data) in enumerate(tokens.items()):
        offering = token_data["offeringDetails"]
        az_num   = idx + 1

        region      = offering.get("Region", "N/A")
        az          = offering.get("Availability Zone", "N/A")
        itype       = offering.get("Instance Type", "N/A")
        icount      = offering.get("Instance Count", "N/A")
        start_date  = offering.get("Start Date", "N/A")
        end_date    = offering.get("End Date", "N/A")
        duration    = offering.get("Duration (days)", "N/A")
        upfront_fee = offering.get("Upfront Fee", "N/A")

        # Other AZs in this batch
        other_lines = ""
        for j, other in enumerate(other_azs):
            if j != idx:
                other_lines += f"  AZ {j+1} of {total}   :   {other}   — email sent\n"

        yes_url  = approval_url(api_url, token, "yes")
        wait_url = approval_url(api_url, token, "wait")
        no_url   = approval_url(api_url, token, "no")

        subject = f"[Action Required] AWS GPU Capacity Available — AZ {az_num} of {total} — {az}"

        body = f"""Dear Team,

This is an automated notification from your AWS GPU Capacity Block
Reservation Pipeline.

A Capacity Block has become available in one of your selected
Availability Zones. This email covers Availability Zone {az_num} of {total}.
A separate email has been sent for each AZ where capacity was found.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  AVAILABILITY ZONE {az_num} OF {total}
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
  OTHER AZ EMAILS SENT SIMULTANEOUSLY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{other_lines if other_lines else "  This was the only AZ with capacity available."}
  Note: Only one AZ can be approved for reservation.
  The first YES click across all emails will move
  that AZ to final confirmation. All other emails
  will be automatically invalidated.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  YOUR OPTIONS — AZ {az_num} OF {total}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  This approval link is specific to {region} / {az} only.
  Approval expires in 4 hours from: {fmt_now()}


  YES — PROCEED TO FINAL CONFIRMATION
  I want this AZ. Send me the final confirmation
  email before the purchase is made.
  {yes_url}


  WAIT — SKIP THIS AZ AND WATCH FOR THE NEXT AVAILABLE
  Skip this AZ and continue watching for capacity
  in the remaining AZs in my configuration.
  {wait_url}


  NO — DECLINE THIS AZ ONLY
  I do not want this AZ. Decline it and keep
  watching the remaining AZs.
  {no_url}


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  WARNING ABOUT THE WAIT OPTION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  If you click WAIT, please read the following carefully:

  • This current availability in {region} / {az} will be
    skipped immediately and permanently. It will
    not be held or revisited.

  • The watcher will continue searching your remaining
    configurations for the next available slot.

  • We cannot guarantee that another slot will become
    available within your remaining search window.
    Capacity Blocks are limited and availability can
    change at any moment.

  • If no further capacity is found before the 48-hour
    window expires, you will receive the timeout email
    and will need to choose between Retry or Quit.

  • AWS does not reserve or hold availability on your
    behalf while you are deciding. This slot may no
    longer be available by the time you respond.

  By clicking WAIT you acknowledge and accept these
  conditions.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  IMPORTANT NOTES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • Clicking YES does not immediately charge your
    account. You will receive one final confirmation
    email where you must confirm again before any
    purchase is made.

  • Clicking NO declines only this AZ. Other AZ
    emails remain active and independent.

  • Clicking NO on all AZ emails will stop the
    pipeline and delete all temporary watcher
    services. No charge will be made.

  • This link expires in 4 hours.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PIPELINE INFORMATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Pipeline Run ID        :   {pipeline_run_id}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This is an automated message. Do not reply to this email.
For questions contact your AWS administrator.

AWS GPU Capacity Block Reservation Pipeline — AZ {az_num} of {total}
Powered by AWS Step Functions · Lambda · EventBridge
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"""

        publish_email(sns_arn, subject, body)
        print(f"[lambda_notify] Sent AZ {az_num}/{total} email for {region}/{az}")

# ---------------------------------------------------------------------------
def send_final_confirmation_email(offering: dict, token: str,
                                   sns_arn: str, api_url: str,
                                   pipeline_run_id: str) -> None:
    """Send the single final confirmation email — last step before purchase."""
    region      = offering.get("Region", "N/A")
    az          = offering.get("Availability Zone", "N/A")
    itype       = offering.get("Instance Type", "N/A")
    icount      = offering.get("Instance Count", "N/A")
    start_date  = offering.get("Start Date", "N/A")
    end_date    = offering.get("End Date", "N/A")
    duration    = offering.get("Duration (days)", "N/A")
    upfront_fee = offering.get("Upfront Fee", "N/A")

    confirm_token = f"final-{str(uuid.uuid4())[:12]}"
    get_table().put_item(Item={
        "pk": f"final-token-{confirm_token}",
        "token": confirm_token,
        "type": "final_confirmation",
        "offeringDetails": json.dumps(offering, default=str),
        "originalToken": token,
        "status": "pending",
        "createdAt": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pipelineRunId": pipeline_run_id
    })
    put_param("final-confirm-token", confirm_token)

    confirm_url = f"{api_url}/approve?token={confirm_token}&decision=confirm&pid={pipeline_run_id}"
    cancel_url  = f"{api_url}/approve?token={confirm_token}&decision=cancel&pid={pipeline_run_id}"

    subject = f"[FINAL CONFIRMATION REQUIRED] AWS GPU Capacity Block — {region} / {az} — {upfront_fee}"
    body = f"""Dear Team,

This is your FINAL CONFIRMATION REQUEST for the AWS GPU Capacity
Block Reservation. You are one step away from committing to this
purchase.

Please read all details carefully before confirming. This is the
last step. Once confirmed, the reservation will be purchased
immediately and the upfront fee will be charged to your AWS account.

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
  PIPELINE INFORMATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Pipeline Run ID        :   {pipeline_run_id}
  This Email Sent At     :   {fmt_now()}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  WARNING — READ BEFORE CONFIRMING
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • Clicking CONFIRM PURCHASE below will immediately
    and irrevocably charge {upfront_fee} to your AWS account.

  • Capacity Blocks cannot be cancelled once purchased.
    There are no refunds.

  • Ensure the instance type, count, region, AZ, and
    dates above match exactly what your team requires
    before clicking.

  • This final confirmation link expires in 30 minutes
    from: {fmt_now()}

    If this link expires, the pipeline will pause and
    send you a fresh final confirmation email.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  FINAL ACTION — ONE CLICK TO CONFIRM
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  CONFIRM PURCHASE — {upfront_fee}
  I have verified all details above. I authorise the
  immediate purchase of this Capacity Block reservation.
  {confirm_url}


  CANCEL — DO NOT PURCHASE
  Cancel this reservation. Stop the pipeline and clean
  up all temporary watcher services. No charge will
  be made.
  {cancel_url}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This is an automated message. Do not reply to this email.
For questions contact your AWS administrator.

AWS GPU Capacity Block Reservation Pipeline — FINAL CONFIRMATION
Powered by AWS Step Functions · Lambda · EventBridge
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"""

    publish_email(sns_arn, subject, body)
    print(f"[lambda_notify] Final confirmation email sent for {region}/{az}")

# ---------------------------------------------------------------------------
def send_timeout_email(sns_arn: str, api_url: str,
                        pipeline_run_id: str, attempts: int,
                        combinations: list) -> None:
    retry_url = f"{api_url}/approve?token=timeout-{pipeline_run_id}&decision=retry&pid={pipeline_run_id}"
    quit_url  = f"{api_url}/approve?token=timeout-{pipeline_run_id}&decision=quit&pid={pipeline_run_id}"

    combo_lines = ""
    for i, c in enumerate(combinations, 1):
        combo_lines += f"  {i}.  Instance Type : {c.get('instance_type','N/A')}  |  Region : {c.get('region','N/A')}  |  AZ : {c.get('az','N/A')}\n      Result        : No availability found\n\n"

    subject = "[Action Required] AWS GPU Capacity — No Availability Found After 48 Hours"
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
  CONFIGURATIONS SEARCHED — NO AVAILABILITY FOUND
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{combo_lines}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ACTION REQUIRED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Please choose one of the following options.
  This link expires in 4 hours from: {fmt_now()}

  RETRY — SEARCH AGAIN FOR 48 HOURS
  A fresh 48-hour search window will begin immediately
  using the same configuration.
  {retry_url}

  QUIT — STOP AND CLEAN UP
  All temporary AWS watcher services will be deleted.
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
# ---------------------------------------------------------------------------
def send_pipeline_started_email(sns_arn: str, pipeline_run_id: str,
                                 combinations: list, instance_count: str,
                                 duration_days: str, max_hours: str,
                                 retry_mins: str) -> None:
    combo_lines = ""
    for i, c in enumerate(combinations, 1):
        combo_lines += f"  {i}.  {c.get('instance_type','N/A')}  |  {c.get('region','N/A')}  |  {c.get('az','N/A')}\n"

    subject = f"[Started] AWS GPU Capacity Block Pipeline Started — {pipeline_run_id}"
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

  You will receive emails for:
    • Every scan attempt (heartbeat every 15 minutes)
    • Capacity found — with YES / WAIT / NO links
    • 48-hour timeout — with Retry / Quit links
    • Pipeline completed — when cluster is live

  No action needed right now.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This is an automated message. Do not reply to this email.

AWS GPU Capacity Block Reservation Pipeline
Powered by AWS Step Functions · Lambda · EventBridge
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"""

    sns.publish(TopicArn=sns_arn, Subject=subject, Message=body)
    print(f"[lambda_notify] Pipeline started email sent")


# ---------------------------------------------------------------------------
def send_scan_heartbeat_email(sns_arn: str, pipeline_run_id: str,
                               attempt: int, max_attempts: int,
                               combinations: list, errors: list) -> None:
    mins_done  = attempt * 15
    hours_done = mins_done // 60
    mins_left  = (max_attempts - attempt) * 15
    hours_left = mins_left // 60
    mins_left_r= mins_left % 60
    pct        = round(attempt / max_attempts * 100, 1)

    combo_lines = ""
    for c in combinations:
        combo_lines += f"  {c.get('instance_type','N/A')}  |  {c.get('region','N/A')}  |  {c.get('az','N/A')}  ->  No availability\n"

    error_section = ""
    if errors:
        error_section = "\n  Note: Some regions returned API errors (normal for unsupported instance types)\n"
        for e in errors[:3]:
            error_section += f"  {e.get('Region','?')}  :  {e.get('Error','?')}\n"

    subject = f"[Scan {attempt}/{max_attempts}] No capacity found yet — {pct}% complete"
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

This is an automated message. Do not reply to this email.

AWS GPU Capacity Block Reservation Pipeline
Powered by AWS Step Functions · Lambda · EventBridge
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"""

    sns.publish(TopicArn=sns_arn, Subject=subject, Message=body)
    print(f"[lambda_notify] Heartbeat email sent — attempt {attempt}/{max_attempts}")


# ---------------------------------------------------------------------------
def send_retry_started_email(sns_arn: str, pipeline_run_id: str,
                              combinations: list, max_hours: str,
                              retry_mins: str) -> None:
    combo_lines = ""
    for i, c in enumerate(combinations, 1):
        combo_lines += f"  {i}.  {c.get('instance_type','N/A')}  |  {c.get('region','N/A')}  |  {c.get('az','N/A')}\n"

    subject = "[Retrying] AWS GPU Capacity Search — Fresh 48-Hour Window Started"
    body = f"""Dear Team,

You clicked RETRY. A fresh 48-hour search window has started.

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
def handler(event: dict, context) -> dict:
    action          = event.get("action", "notify_found")
    pipeline_run_id = event.get("pipelineRunId", PIPELINE_ID)
    print(f"[lambda_notify] action={action}")

    sns_arn = get_param("sns-topic-arn")
    api_url = get_param("api-gateway-url")

    if not sns_arn:
        print("[lambda_notify] No SNS ARN found — cannot send email")
        return {"sent": False, "error": "No SNS ARN"}

    # ── notify_found: send per-AZ emails ─────────────────────────────────────
    if action == "notify_found":
        offerings_raw = get_param("found-offerings")
        offerings = json.loads(offerings_raw) if offerings_raw else []
        if not offerings:
            return {"sent": False, "error": "No offerings to notify"}
        send_capacity_found_emails(offerings, sns_arn, api_url, pipeline_run_id)
        return {"sent": True, "emailCount": len(offerings)}

    # ── send_final_confirmation ───────────────────────────────────────────────
    if action == "send_final_confirmation":
        token         = event.get("token", "")
        offering_raw  = get_param("selected-offering")
        offering      = json.loads(offering_raw) if offering_raw else {}
        if not offering:
            return {"sent": False, "error": "No selected offering"}
        send_final_confirmation_email(offering, token, sns_arn, api_url, pipeline_run_id)
        return {"sent": True}

    # ── notify_timeout: 48-hour expiry email ──────────────────────────────────
    if action == "notify_timeout":
        state      = get_table().get_item(Key={"pk": "watcher-state"}).get("Item", {})
        attempts   = int(state.get("attemptCount", 0))
        combo_str  = get_param("combinations")
        combos     = [{"instance_type": p.split("|")[0],
                       "region": p.split("|")[1],
                       "az": p.split("|")[2]}
                      for p in combo_str.split(";") if "|" in p]
        send_timeout_email(sns_arn, api_url, pipeline_run_id, attempts, combos)
        return {"sent": True}

    # ── send_reminder ────────────────────────────────────────────────────────
    if action == "send_reminder":
        offerings_raw = get_param("found-offerings")
        offerings = json.loads(offerings_raw) if offerings_raw else []
        if offerings:
            send_capacity_found_emails(offerings, sns_arn, api_url, pipeline_run_id)
        return {"sent": True, "type": "reminder"}

    # ── notify_error ─────────────────────────────────────────────────────────
    if action == "notify_error":
        error_msg = event.get("error", "Unknown error")
        sns.publish(
            TopicArn=sns_arn,
            Subject=f"[ERROR] AWS GPU Capacity Pipeline Failed — {pipeline_run_id}",
            Message=f"Pipeline {pipeline_run_id} encountered an error:\n\n{error_msg}\n\nCheck CloudWatch logs for details."
        )
        return {"sent": True}

    # ── pipeline_started: first scan email ──────────────────────────────────
    if action == "pipeline_started":
        combo_str  = get_param("combinations")
        combos     = [{"instance_type": p.split("|")[0],
                       "region":        p.split("|")[1],
                       "az":            p.split("|")[2]}
                      for p in combo_str.split(";") if "|" in p]
        send_pipeline_started_email(
            sns_arn, pipeline_run_id,
            combos,
            get_param("instance-count"),
            get_param("duration-days"),
            get_param("max-hours"),
            get_param("retry-mins"),
        )
        return {"sent": True}

    # ── scan_heartbeat: sent after every scan attempt ────────────────────────
    if action == "scan_heartbeat":
        attempt      = int(event.get("attempt", 0))
        max_attempts = int(event.get("maxAttempts", 192))
        errors       = event.get("errors", [])
        combo_str    = get_param("combinations")
        combos       = [{"instance_type": p.split("|")[0],
                         "region":        p.split("|")[1],
                         "az":            p.split("|")[2]}
                        for p in combo_str.split(";") if "|" in p]
        send_scan_heartbeat_email(
            sns_arn, pipeline_run_id,
            attempt, max_attempts, combos, errors
        )
        return {"sent": True}

    # ── notify_retry_started: sent when user clicks Retry ───────────────────
    if action == "notify_retry_started":
        combo_str = get_param("combinations")
        combos    = [{"instance_type": p.split("|")[0],
                      "region":        p.split("|")[1],
                      "az":            p.split("|")[2]}
                     for p in combo_str.split(";") if "|" in p]
        send_retry_started_email(
            sns_arn, pipeline_run_id,
            combos,
            get_param("max-hours"),
            get_param("retry-mins"),
        )
        return {"sent": True}

    return {"sent": False, "error": f"Unknown action: {action}"}