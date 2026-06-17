"""
lambda_notify.py — GPU Watcher Notification Lambda (multi-AZ)

MULTI-AZ EMAIL FLOW:
  - Capacity found in N AZs → N emails sent simultaneously
  - Each email has PROCEED and REJECT links
  - First PROCEED → final confirmation email for that AZ
                  → cancellation follow-up email sent to all other AZs
  - REJECT one AZ → other AZ emails remain active
  - All AZs rejected → pipeline stops, 'no AZ selected' email sent
"""

import os, json, uuid, boto3
from datetime import datetime, timezone

AWS_REGION  = os.environ.get("AWS_REGION_NAME", "us-east-1")
SSM_PREFIX  = os.environ.get("SSM_PREFIX", "")
TABLE_NAME  = os.environ.get("TABLE_NAME", "")
PIPELINE_ID = os.environ.get("PIPELINE_RUN_ID", "")

ssm    = boto3.client("ssm",        region_name=AWS_REGION)
sns    = boto3.client("sns",        region_name=AWS_REGION)
dynamo = boto3.resource("dynamodb", region_name=AWS_REGION)

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

def publish(sns_arn, subject, body):
    sns.publish(TopicArn=sns_arn, Subject=subject, Message=body)

def approval_url(api_url, token, decision):
    return f"{api_url}/approve?token={token}&decision={decision}&pid={PIPELINE_ID}"

def fmt_now():
    return datetime.now(timezone.utc).strftime("%d %B %Y, %I:%M %p UTC")

SEP = "━" * 46

# ── 1. CAPACITY FOUND — one email per AZ simultaneously ──────────────────────
def send_capacity_found_emails(offerings, sns_arn, api_url, pipeline_run_id):
    total = len(offerings)

    # Create one token per AZ
    all_tokens = [str(uuid.uuid4())[:16] for _ in offerings]

    # Write all tokens to DynamoDB
    for idx, (token, offering) in enumerate(zip(all_tokens, offerings)):
        get_table().put_item(Item={
            "pk":              f"proceed-token-{token}",
            "token":           token,
            "type":            "az_proceed",
            "offeringIndex":   idx,
            "offeringDetails": json.dumps(offering, default=str),
            "allTokens":       all_tokens,
            "status":          "pending",
            "createdAt":       datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "pipelineRunId":   pipeline_run_id,
        })

    put_param("az-tokens", json.dumps(all_tokens))

    # Send one email per AZ
    for idx, (token, offering) in enumerate(zip(all_tokens, offerings)):
        az_num      = idx + 1
        region      = offering.get("Region",            "N/A")
        az          = offering.get("Availability Zone",  "N/A")
        itype       = offering.get("Instance Type",      "N/A")
        icount      = offering.get("Instance Count",     "N/A")
        start_date  = offering.get("Start Date",         "N/A")
        end_date    = offering.get("End Date",           "N/A")
        duration    = offering.get("Duration (days)",    "N/A")
        upfront_fee = offering.get("Upfront Fee",        "N/A")

        proceed_url = approval_url(api_url, token, "proceed")
        reject_url  = approval_url(api_url, token, "reject")

        # Lines describing all OTHER AZs in this batch
        other_lines = ""
        for j, other_offering in enumerate(offerings):
            if j != idx:
                other_lines += (
                    f"  AZ {j+1}  :  "
                    f"{other_offering.get('Region','N/A')} / "
                    f"{other_offering.get('Availability Zone','N/A')}  |  "
                    f"Fee: {other_offering.get('Upfront Fee','N/A')}"
                    f"  ← separate email sent\n"
                )

        subject = (
            f"[Action Required — AZ {az_num}/{total}] "
            f"GPU Capacity Found — {region} / {az} — {upfront_fee}"
        )

        body = f"""Dear Team,

GPU Capacity Block availability has been found.
{total} AZ email(s) sent simultaneously — one per available zone.
First PROCEED click wins. Clicking PROCEED cancels all other AZ emails.

{SEP}
  THIS EMAIL — AZ {az_num} OF {total}
{SEP}

  Instance Type          :   {itype}
  Instance Count         :   {icount}
  Region                 :   {region}
  Availability Zone      :   {az}
  Start Date             :   {start_date}
  End Date               :   {end_date}
  Duration               :   {duration} days
  Upfront Fee            :   {upfront_fee}

{SEP}
  OTHER AZ EMAILS SENT SIMULTANEOUSLY
{SEP}

{other_lines if other_lines else "  This is the only AZ with capacity available.\n"}
{SEP}
  YOUR OPTIONS FOR AZ {az_num} — {az}
{SEP}

  PROCEED WITH THIS AZ
  Select {region} / {az} and receive the final
  confirmation email. All other AZ emails will be
  cancelled and you will receive a cancellation notice.
  Clicking PROCEED does NOT charge your account.

  {proceed_url}


  REJECT THIS AZ
  Decline {region} / {az}.
  Other AZ email(s) remain active in your inbox.
  If you reject ALL AZs the pipeline will stop and
  you will receive a notification email.

  {reject_url}

{SEP}
  HOW THIS WORKS
{SEP}

  • PROCEED on ANY email → cancels all other AZ emails
    (you receive a cancellation notice for each) and
    moves to final confirmation for your chosen AZ only.

  • REJECT on this email → keeps all other AZ emails
    active. Check your inbox for the other AZ option(s).

  • Reject ALL AZs → pipeline stops, you receive a
    'no AZ selected' notification email.

  • These links expire in 4 hours from: {fmt_now()}

{SEP}
  PIPELINE CONTROLS
{SEP}

  Stop the watcher (infrastructure kept):
  {approval_url(api_url, f"ctrl-{pipeline_run_id}", "stop")}

  Stop and delete ALL resources:
  {approval_url(api_url, f"ctrl-{pipeline_run_id}", "stop_terminate")}

  Pipeline Run ID        :   {pipeline_run_id}
  Email sent at          :   {fmt_now()}
{SEP}

This is an automated message. Do not reply to this email.
AWS GPU Capacity Block Reservation Pipeline — AZ {az_num} of {total}
"""
        publish(sns_arn, subject, body)
        print(f"[lambda_notify] AZ {az_num}/{total} email sent: {region}/{az} token={token[:8]}")

    print(f"[lambda_notify] {total} simultaneous AZ email(s) sent")


# ── 2. AZ CANCELLED FOLLOW-UP — sent when another AZ was chosen ──────────────
def send_az_cancelled_email(cancelled_offering, chosen_offering,
                             sns_arn, pipeline_run_id):
    c_region = cancelled_offering.get("Region",            "N/A")
    c_az     = cancelled_offering.get("Availability Zone",  "N/A")
    w_region = chosen_offering.get("Region",               "N/A")
    w_az     = chosen_offering.get("Availability Zone",     "N/A")
    w_fee    = chosen_offering.get("Upfront Fee",           "N/A")

    subject = (
        f"[Cancelled] GPU Capacity AZ Option — {c_region} / {c_az} — "
        f"Another AZ Was Selected"
    )
    body = f"""Dear Team,

This is a notification that the AZ option you received for
{c_region} / {c_az} has been cancelled.

{SEP}
  REASON FOR CANCELLATION
{SEP}

  Another AZ was selected by clicking PROCEED on a
  different AZ email before this one was acted on.

  Selected AZ  :   {w_region} / {w_az}
  Upfront Fee  :   {w_fee}

  The final confirmation email for {w_region} / {w_az}
  has been sent. No action is required on this email.

{SEP}
  WHAT HAPPENS NEXT
{SEP}

  A final confirmation email for {w_region} / {w_az}
  has been sent. Check your inbox and click
  CONFIRM PURCHASE to complete the reservation,
  or CANCEL to stop the pipeline.

{SEP}

  Pipeline Run ID  :   {pipeline_run_id}
  Cancelled at     :   {fmt_now()}
{SEP}

This is an automated message. Do not reply to this email.
AWS GPU Capacity Block Reservation Pipeline
"""
    publish(sns_arn, subject, body)
    print(f"[lambda_notify] Cancellation follow-up sent for {c_region}/{c_az}")


# ── 3. ALL AZs REJECTED — pipeline stopping ───────────────────────────────────
def send_all_az_rejected_email(offerings, sns_arn, api_url, pipeline_run_id):
    rejected_lines = ""
    for i, o in enumerate(offerings, 1):
        rejected_lines += (
            f"  AZ {i}  :  {o.get('Region','N/A')} / "
            f"{o.get('Availability Zone','N/A')}  |  "
            f"Fee: {o.get('Upfront Fee','N/A')}  — Rejected\n"
        )

    subject = (
        f"[Pipeline Stopped] All AZ Options Rejected — "
        f"{pipeline_run_id}"
    )
    body = f"""Dear Team,

All available AZ options have been rejected.
The pipeline has stopped and all watcher services
are being deleted.

{SEP}
  REJECTED AZ OPTIONS
{SEP}

{rejected_lines}
{SEP}
  WHAT HAPPENS NEXT
{SEP}

  All temporary watcher services (Lambda, Step
  Functions, DynamoDB, API Gateway, EventBridge)
  are being deleted now.

  Your permanent infrastructure (key pair, subnet,
  security group, placement group, IAM profile,
  launch template, SNS topic) has NOT been touched.

  To run a new search with different settings,
  update config.env and run: bash main.sh

{SEP}

  Pipeline Run ID  :   {pipeline_run_id}
  Stopped at       :   {fmt_now()}
{SEP}

This is an automated message. Do not reply to this email.
AWS GPU Capacity Block Reservation Pipeline
"""
    publish(sns_arn, subject, body)
    print(f"[lambda_notify] All-AZ-rejected email sent for {pipeline_run_id}")


# ── 4. FINAL CONFIRMATION ─────────────────────────────────────────────────────
def send_final_confirmation_email(offering, proceed_token, sns_arn,
                                   api_url, pipeline_run_id):
    region      = offering.get("Region",            "N/A")
    az          = offering.get("Availability Zone",  "N/A")
    itype       = offering.get("Instance Type",      "N/A")
    icount      = offering.get("Instance Count",     "N/A")
    start_date  = offering.get("Start Date",         "N/A")
    end_date    = offering.get("End Date",           "N/A")
    duration    = offering.get("Duration (days)",    "N/A")
    upfront_fee = offering.get("Upfront Fee",        "N/A")

    confirm_token = f"final-{str(uuid.uuid4())[:12]}"
    get_table().put_item(Item={
        "pk":              f"final-token-{confirm_token}",
        "token":           confirm_token,
        "type":            "final_confirmation",
        "offeringDetails": json.dumps(offering, default=str),
        "proceedToken":    proceed_token,
        "status":          "pending",
        "createdAt":       datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pipelineRunId":   pipeline_run_id,
    })
    put_param("final-confirm-token", confirm_token)

    confirm_url = approval_url(api_url, confirm_token, "confirm")
    cancel_url  = approval_url(api_url, confirm_token, "cancel")

    subject = (
        f"[FINAL CONFIRMATION] AWS GPU Capacity Block — "
        f"{region} / {az} — {upfront_fee}"
    )
    body = f"""Dear Team,

You clicked PROCEED for {region} / {az}.
All other AZ emails have been cancelled.
This is your FINAL CONFIRMATION REQUEST.

{SEP}
  RESERVATION DETAILS — PLEASE VERIFY CAREFULLY
{SEP}

  Instance Type          :   {itype}
  Instance Count         :   {icount}
  Region                 :   {region}
  Availability Zone      :   {az}
  Start Date             :   {start_date}
  End Date               :   {end_date}
  Duration               :   {duration} days
  Upfront Fee            :   {upfront_fee}

{SEP}
  WARNING — READ BEFORE CONFIRMING
{SEP}

  • Clicking CONFIRM PURCHASE will IMMEDIATELY and
    IRREVOCABLY charge {upfront_fee} to your AWS account.

  • Capacity Blocks CANNOT be cancelled once purchased.
    There are NO refunds.

  • This link expires in 30 minutes from: {fmt_now()}

{SEP}
  YOUR FINAL DECISION
{SEP}

  CONFIRM PURCHASE — {upfront_fee}
  I authorise the immediate purchase of this reservation.
  {confirm_url}


  CANCEL — DO NOT PURCHASE
  No charge. Watcher services will be deleted.
  {cancel_url}

{SEP}

  Pipeline Run ID        :   {pipeline_run_id}
  Email sent at          :   {fmt_now()}
{SEP}

This is an automated message. Do not reply to this email.
AWS GPU Capacity Block Reservation Pipeline — FINAL CONFIRMATION
"""
    publish(sns_arn, subject, body)
    print(f"[lambda_notify] Final confirmation email sent for {region}/{az}")


# ── 5. PIPELINE STARTED ───────────────────────────────────────────────────────
def send_pipeline_started_email(sns_arn, pipeline_run_id, combinations,
                                 instance_count, duration_days,
                                 max_hours, retry_mins):
    combo_lines = "".join(
        f"  {i}.  {c.get('instance_type','N/A')}  |  "
        f"{c.get('region','N/A')}  |  AZ: {c.get('az','N/A')}\n"
        for i, c in enumerate(combinations, 1)
    )
    subject = f"[Started] AWS GPU Capacity Block Pipeline — {pipeline_run_id}"
    body = f"""Dear Team,

Your AWS GPU Capacity Block Reservation Pipeline has started.

{SEP}
  PIPELINE DETAILS
{SEP}

  Pipeline Run ID        :   {pipeline_run_id}
  Started At             :   {fmt_now()}
  Instance Count         :   {instance_count}
  Duration               :   {duration_days} days
  Scan Interval          :   Every {retry_mins} minutes
  Max Search Window      :   {max_hours} hours

{SEP}
  COMBINATIONS BEING SEARCHED
{SEP}

{combo_lines}
{SEP}
  WHAT HAPPENS NEXT
{SEP}

  When capacity is found you receive one email per AZ
  simultaneously. First PROCEED click wins and cancels
  all other AZ emails. Click REJECT to decline that AZ
  while keeping other AZ emails active.
  Rejecting ALL AZs stops the pipeline.

{SEP}

This is an automated message. Do not reply to this email.
AWS GPU Capacity Block Reservation Pipeline
"""
    sns.publish(TopicArn=sns_arn, Subject=subject, Message=body)
    print("[lambda_notify] Pipeline started email sent")


# ── 6. TIMEOUT ────────────────────────────────────────────────────────────────
def send_timeout_email(sns_arn, api_url, pipeline_run_id,
                        attempts, combinations):
    combo_lines = "".join(
        f"  {i}.  {c.get('instance_type','N/A')}  |  "
        f"{c.get('region','N/A')}  |  AZ: {c.get('az','N/A')}  →  None found\n"
        for i, c in enumerate(combinations, 1)
    )
    retry_url = approval_url(api_url, f"timeout-{pipeline_run_id}", "retry")
    quit_url  = approval_url(api_url, f"timeout-{pipeline_run_id}", "quit")

    subject = "[Action Required] GPU Capacity — No Availability After 48 Hours"
    body = f"""Dear Team,

The 48-hour search window elapsed without finding capacity.

{SEP}
  SEARCH SUMMARY
{SEP}

  Total Attempts         :   {attempts}
  Search Duration        :   48 hours
  Ended At               :   {fmt_now()}

{SEP}
  COMBINATIONS SEARCHED
{SEP}

{combo_lines}
{SEP}
  YOUR OPTIONS — link expires in 4 hours
{SEP}

  RETRY — Search again for another 48 hours
  {retry_url}

  QUIT — Stop and clean up all watcher services
  {quit_url}

{SEP}

  Pipeline Run ID        :   {pipeline_run_id}
{SEP}

This is an automated message. Do not reply to this email.
AWS GPU Capacity Block Reservation Pipeline
"""
    publish(sns_arn, subject, body)
    print("[lambda_notify] 48-hour timeout email sent")


# ── 7. HEARTBEAT ──────────────────────────────────────────────────────────────
def send_scan_heartbeat_email(sns_arn, pipeline_run_id, attempt,
                               max_attempts, combinations, errors, api_url):
    mins_done  = attempt * 15
    mins_left  = (max_attempts - attempt) * 15
    pct        = round(attempt / max_attempts * 100, 1)

    combo_lines = "".join(
        f"  {c.get('instance_type','N/A')}  |  "
        f"{c.get('region','N/A')}  |  AZ: {c.get('az','N/A')}  →  None\n"
        for c in combinations
    )
    subject = (f"[Scan {attempt}/{max_attempts}] "
               f"No capacity found yet — {pct}% complete")
    body = f"""Dear Team,

Scan {attempt} of {max_attempts} completed. No GPU capacity found yet.

  Attempts so far        :   {attempt} / {max_attempts}
  Progress               :   {pct}%
  Time elapsed           :   ~{mins_done // 60}h {mins_done % 60}m
  Time remaining         :   ~{mins_left // 60}h {mins_left % 60}m
  Scanned at             :   {fmt_now()}

{SEP}
  SCAN RESULT
{SEP}

{combo_lines}
  Next scan in 15 minutes. No action needed.

{SEP}
  PIPELINE CONTROLS
{SEP}

  Stop (watcher deleted, infrastructure kept):
  {approval_url(api_url, f"ctrl-{pipeline_run_id}", "stop")}

  Stop and delete ALL resources:
  {approval_url(api_url, f"ctrl-{pipeline_run_id}", "stop_terminate")}

  Restart with fresh 48-hour window:
  {approval_url(api_url, f"ctrl-{pipeline_run_id}", "restart")}

  Pipeline Run ID        :   {pipeline_run_id}
{SEP}

This is an automated message. Do not reply to this email.
AWS GPU Capacity Block Reservation Pipeline
"""
    sns.publish(TopicArn=sns_arn, Subject=subject, Message=body)
    print(f"[lambda_notify] Heartbeat sent — attempt {attempt}/{max_attempts}")


# ── 8. RETRY STARTED ──────────────────────────────────────────────────────────
def send_retry_started_email(sns_arn, pipeline_run_id, combinations,
                              max_hours, retry_mins):
    combo_lines = "".join(
        f"  {i}.  {c.get('instance_type','N/A')}  |  "
        f"{c.get('region','N/A')}  |  AZ: {c.get('az','N/A')}\n"
        for i, c in enumerate(combinations, 1)
    )
    subject = "[Retrying] AWS GPU Capacity Search — Fresh 48-Hour Window"
    body = f"""Dear Team,

You clicked RETRY. A fresh 48-hour search window has started.

  Pipeline Run ID        :   {pipeline_run_id}
  Retry Started At       :   {fmt_now()}
  New Search Window      :   {max_hours} hours
  Scan Interval          :   Every {retry_mins} minutes

{combo_lines}

This is an automated message. Do not reply to this email.
AWS GPU Capacity Block Reservation Pipeline
"""
    sns.publish(TopicArn=sns_arn, Subject=subject, Message=body)
    print("[lambda_notify] Retry started email sent")


# ── HANDLER ───────────────────────────────────────────────────────────────────
def handler(event, context):
    action          = event.get("action", "notify_found")
    pipeline_run_id = event.get("pipelineRunId", PIPELINE_ID)
    print(f"[lambda_notify] action={action}")

    sns_arn = get_param("sns-topic-arn")
    api_url = get_param("api-gateway-url")

    if not sns_arn:
        print("[lambda_notify] No SNS ARN — cannot send email")
        return {"sent": False, "error": "No SNS ARN"}

    def parse_combos():
        combo_str = get_param("combinations")
        return [
            {"instance_type": p.split("|")[0],
             "region":        p.split("|")[1],
             "az":            p.split("|")[2]}
            for p in combo_str.split(";") if "|" in p
        ]

    if action == "notify_found":
        offerings_raw = get_param("found-offerings")
        offerings     = json.loads(offerings_raw) if offerings_raw else []
        if not offerings:
            return {"sent": False, "error": "No offerings"}
        send_capacity_found_emails(offerings, sns_arn, api_url, pipeline_run_id)
        return {"sent": True, "emailCount": len(offerings)}

    if action == "send_az_cancelled":
        # Called by lambda_approve when another AZ is chosen
        cancelled_offering = event.get("cancelledOffering", {})
        chosen_offering    = event.get("chosenOffering",    {})
        send_az_cancelled_email(cancelled_offering, chosen_offering,
                                sns_arn, pipeline_run_id)
        return {"sent": True}

    if action == "send_all_az_rejected":
        offerings_raw = get_param("found-offerings")
        offerings     = json.loads(offerings_raw) if offerings_raw else []
        send_all_az_rejected_email(offerings, sns_arn, api_url, pipeline_run_id)
        return {"sent": True}

    if action == "send_final_confirmation":
        proceed_token = event.get("token", get_param("proceed-token"))
        offering_raw  = get_param("selected-offering")
        offering      = json.loads(offering_raw) if offering_raw else {}
        if not offering:
            return {"sent": False, "error": "No selected offering"}
        send_final_confirmation_email(offering, proceed_token, sns_arn,
                                       api_url, pipeline_run_id)
        return {"sent": True}

    if action == "notify_timeout":
        state    = get_table().get_item(
            Key={"pk": "watcher-state"}).get("Item", {})
        attempts = int(state.get("attemptCount", 0))
        send_timeout_email(sns_arn, api_url, pipeline_run_id,
                           attempts, parse_combos())
        return {"sent": True}

    if action == "notify_error":
        error_msg = event.get("error", "Unknown error")
        sns.publish(
            TopicArn=sns_arn,
            Subject=f"[ERROR] GPU Capacity Pipeline Failed — {pipeline_run_id}",
            Message=f"Pipeline {pipeline_run_id} error:\n\n{error_msg}"
        )
        return {"sent": True}

    if action == "pipeline_started":
        send_pipeline_started_email(
            sns_arn, pipeline_run_id, parse_combos(),
            get_param("instance-count"), get_param("duration-days"),
            get_param("max-hours"),      get_param("retry-mins"),
        )
        return {"sent": True}

    if action == "scan_heartbeat":
        send_scan_heartbeat_email(
            sns_arn, pipeline_run_id,
            int(event.get("attempt", 0)),
            int(event.get("maxAttempts", 192)),
            parse_combos(),
            event.get("errors", []),
            api_url,
        )
        return {"sent": True}

    if action == "notify_retry_started":
        send_retry_started_email(
            sns_arn, pipeline_run_id, parse_combos(),
            get_param("max-hours"), get_param("retry-mins"),
        )
        return {"sent": True}

    return {"sent": False, "error": f"Unknown action: {action}"}