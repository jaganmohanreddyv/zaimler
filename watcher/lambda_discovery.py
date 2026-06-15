"""
lambda_discovery.py — GPU Watcher Discovery Lambda
Called by Step Functions every 15 minutes.

Calls the EC2 describe_capacity_block_offerings API directly.
The three functions (scan_region, run_parallel, process_results) are
inlined from the official AWS capacity finder app.py so we never need
to import that file (it executes Streamlit UI code at module level
which crashes in a Lambda environment).

Zero external dependencies beyond boto3 (pre-installed in Lambda).
"""

import os
import json
import boto3
import concurrent.futures
import inspect
from datetime import datetime, date
from decimal import Decimal

AWS_REGION  = os.environ.get("AWS_REGION_NAME", "us-east-1")
SSM_PREFIX  = os.environ.get("SSM_PREFIX", "")
TABLE_NAME  = os.environ.get("TABLE_NAME", "")
PIPELINE_ID = os.environ.get("PIPELINE_RUN_ID", "")

ssm    = boto3.client("ssm",      region_name=AWS_REGION)
dynamo = boto3.resource("dynamodb", region_name=AWS_REGION)

MAX_WORKERS = 8

# ---------------------------------------------------------------------------
# Helpers — SSM / DynamoDB
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
        print(f"[WARN] Could not write SSM {key}: {e}")

def get_table():
    return dynamo.Table(TABLE_NAME)

def invoke_notify(action: str, extra: dict = None) -> None:
    """Fire-and-forget call to lambda_notify for email sending."""
    try:
        lmb = boto3.client("lambda", region_name=AWS_REGION)
        payload = {"action": action, "pipelineRunId": PIPELINE_ID}
        if extra:
            payload.update(extra)
        lmb.invoke(
            FunctionName=f"gpu-watcher-notify-{PIPELINE_ID}",
            InvocationType="Event",  # async — don't wait for response
            Payload=json.dumps(payload).encode(),
        )
        print(f"[lambda_discovery] Invoked notify action={action}")
    except Exception as e:
        print(f"[WARN] Could not invoke notify Lambda: {e}")

def get_state() -> dict:
    try:
        resp = get_table().get_item(Key={"pk": "watcher-state"})
        return resp.get("Item", {})
    except Exception:
        return {}

def update_state(**kwargs) -> None:
    update_expr = "SET " + ", ".join(f"#{k}=:{k}" for k in kwargs)
    expr_names  = {f"#{k}": k for k in kwargs}
    expr_values = {f":{k}": v for k, v in kwargs.items()}
    get_table().update_item(
        Key={"pk": "watcher-state"},
        UpdateExpression=update_expr,
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_values
    )

# ---------------------------------------------------------------------------
# Capacity discovery — inlined from app.py, no Streamlit dependency
# ---------------------------------------------------------------------------

def log_msg(msg, region=None, instance_type=None):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    func_name = inspect.currentframe().f_back.f_code.co_name
    parts = [timestamp, func_name]
    if region:        parts.append(f"region={region}")
    if instance_type: parts.append(f"instance_type={instance_type}")
    print(f"[{' | '.join(parts)}] {msg}")

def parse_iso_date(date_val):
    """Convert AWS string/datetime to datetime."""
    if isinstance(date_val, str):
        if date_val.endswith("Z"):
            return datetime.fromisoformat(date_val.replace("Z", "+00:00"))
        return datetime.fromisoformat(date_val)
    return date_val

def scan_region(region: str, itype: str, count: int, duration: int,
                start_dt: date, end_dt=None, use_end_date: bool = False) -> list:
    """
    Call EC2 describe_capacity_block_offerings for one region+instance_type.
    Returns a list of result dicts (or a single-item list with an Error key).
    Inlined from app.py scan_region() — identical logic, no Streamlit globals.
    """
    try:
        ec2 = boto3.client("ec2", region_name=region)
        params = {
            "InstanceType":           itype,
            "InstanceCount":          int(count),
            "CapacityDurationHours":  int(duration * 24),
            "StartDateRange":         datetime.combine(start_dt, datetime.min.time()),
            "MaxResults":             100,
        }
        if use_end_date and end_dt:
            params["EndDateRange"] = datetime.combine(end_dt, datetime.min.time())

        log_msg(f"EC2 params: {params}", region, itype)
        resp = ec2.describe_capacity_block_offerings(**params)
        log_msg(f"EC2 response: {len(resp.get('CapacityBlockOfferings', []))} offerings", region, itype)

        results = []
        for o in resp.get("CapacityBlockOfferings", []):
            s_dt = parse_iso_date(o["StartDate"])
            e_dt = parse_iso_date(o["EndDate"])
            upfront_fee   = f"${o.get('UpfrontFee', '0')}"
            duration_hrs  = o["CapacityBlockDurationHours"]
            reserved      = o.get("ReservedCapacityOfferings", [{}]) or [{}]
            parts_count   = len(reserved)
            results.append({
                "Region":           region,
                "Instance Type":    itype,
                "Instance Count":   str(o.get("InstanceCount", 0)),
                "Duration (days)":  f"{duration_hrs / 24:.2f}",
                "Start Date":       s_dt.strftime("%d/%m/%Y %H:%M"),
                "End Date":         e_dt.strftime("%d/%m/%Y %H:%M"),
                "Upfront Fee":      upfront_fee,
                "Number of Parts":  str(parts_count),
                "Availability Zone": o.get("AvailabilityZone", "N/A"),
                "CapacityBlockOfferingId": o.get("CapacityBlockOfferingId", ""),
            })
        return results
    except Exception as e:
        return [{"Region": region, "Error": str(e)}]

def run_parallel(regions: list, instance_types: list, count: int,
                 duration: int, start_dt: date,
                 end_dt=None, use_end_date: bool = False) -> list:
    """Run scan_region in parallel across all region+type combinations."""
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        futures = [
            ex.submit(scan_region, r, it, count, duration,
                      start_dt, end_dt, use_end_date)
            for r in regions
            for it in instance_types
        ]
        for f in concurrent.futures.as_completed(futures):
            try:
                results.extend(f.result())
            except Exception as e:
                results.append({"Region": "unknown", "Error": str(e)})
    return results

def process_results(raw: list) -> tuple:
    """
    Split raw results into (successes, errors).
    Returns two plain lists of dicts — no pandas dependency.
    """
    successes = [r for r in raw if "Error" not in r]
    errors    = [r for r in raw if "Error" in r]
    return successes, errors

# ---------------------------------------------------------------------------
# Combination helpers
# ---------------------------------------------------------------------------

def parse_combinations(combo_str: str) -> list:
    """Parse 'TYPE|REGION|AZ;TYPE|REGION|AZ' into list of dicts."""
    combos = []
    for item in combo_str.split(";"):
        parts = item.strip().split("|")
        if len(parts) == 3:
            combos.append({
                "instance_type": parts[0].strip(),
                "region":        parts[1].strip(),
                "az":            parts[2].strip(),
            })
    return combos

def filter_by_az(results: list, combinations: list) -> list:
    """Keep only results whose (type, region, AZ) match a requested combination."""
    requested = {
        (c["instance_type"], c["region"], c["az"])
        for c in combinations
    }
    return [
        r for r in results
        if (r.get("Instance Type", ""),
            r.get("Region", ""),
            r.get("Availability Zone", "")) in requested
    ]

# ---------------------------------------------------------------------------
# Timeout check
# ---------------------------------------------------------------------------

def check_timeout(state: dict, max_hours: int) -> bool:
    start_time_str = str(state.get("startTime", ""))
    if not start_time_str:
        return False
    try:
        start_time = datetime.fromisoformat(
            start_time_str.replace("Z", "+00:00")
        )
        elapsed = (datetime.now().astimezone() - start_time).total_seconds() / 3600
        return elapsed >= max_hours
    except Exception:
        return False

# ---------------------------------------------------------------------------
# Lambda handler
# ---------------------------------------------------------------------------

def handler(event: dict, context) -> dict:
    action          = event.get("action", "discover")
    pipeline_run_id = event.get("pipelineRunId", PIPELINE_ID)
    print(f"[lambda_discovery] action={action} pipeline={pipeline_run_id}")

    # ── check_approval ───────────────────────────────────────────────────────
    if action == "check_approval":
        approval = get_param("approval-decision")
        if approval == "confirmed":
            return {"decision": "confirmed"}
        if approval in ("cancelled", "no"):
            return {"decision": "cancelled"}
        if approval == "wait":
            return {"decision": "wait"}
        return {"decision": "pending"}

    # ── check_retry_quit ─────────────────────────────────────────────────────
    if action == "check_retry_quit":
        decision = get_param("retry-quit-decision")
        if decision == "retry":
            return {"decision": "retry"}
        if decision == "quit":
            return {"decision": "quit"}
        return {"decision": "pending"}

    # ── reset_watcher ────────────────────────────────────────────────────────
    if action == "reset_watcher":
        update_state(
            attemptCount=Decimal("0"),
            startTime=datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
            status="running",
        )
        put_param("retry-quit-decision", "")
        put_param("approval-decision",   "")
        invoke_notify("notify_retry_started")
        return {"reset": True}

    # ── discover ─────────────────────────────────────────────────────────────
    state        = get_state()
    attempt      = int(state.get("attemptCount", 0))
    max_attempts = int(state.get("maxAttempts",  192))
    max_hours    = int(state.get("maxHours",     48))

    if check_timeout(state, max_hours) or attempt >= max_attempts:
        update_state(status="timeout", attemptCount=Decimal(str(attempt)))
        print(f"[lambda_discovery] 48-hour window expired after {attempt} attempts")
        return {"found": False, "timeout": True, "attempts": attempt}

    combo_str      = get_param("combinations")
    instance_count = int(get_param("instance-count") or "1")
    duration_days  = int(get_param("duration-days")  or "14")
    start_date_str = get_param("start-date")

    try:
        start_dt = (datetime.strptime(start_date_str, "%Y-%m-%d").date()
                    if start_date_str else date.today())
    except ValueError:
        start_dt = date.today()

    combinations = parse_combinations(combo_str)
    regions_set  = list({c["region"]        for c in combinations})
    types_set    = list({c["instance_type"] for c in combinations})

    print(f"[lambda_discovery] attempt {attempt+1}/{max_attempts} — "
          f"{len(combinations)} combination(s): {combo_str}")

    # Send pipeline started email on the very first scan
    if attempt == 0:
        invoke_notify("pipeline_started")

    raw_results = run_parallel(
        regions_set, types_set, instance_count, duration_days, start_dt
    )
    successes, errors = process_results(raw_results)
    filtered = filter_by_az(successes, combinations)
    attempt += 1

    update_state(
        attemptCount=Decimal(str(attempt)),
        lastChecked=datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        lastResult=json.dumps({"found": len(filtered), "errors": len(errors)}),
        status="running" if not filtered else "found",
    )

    if errors:
        print(f"[lambda_discovery] {len(errors)} scan error(s): "
              + "; ".join(e.get("Error", "") for e in errors[:3]))

    if filtered:
        put_param("found-offerings", json.dumps(filtered))
        print(f"[lambda_discovery] Found {len(filtered)} offering(s)")
        return {"found": True, "timeout": False,
                "offerings": filtered, "attempts": attempt}

    print(f"[lambda_discovery] Nothing found. attempt={attempt}/{max_attempts}")

    # Send heartbeat email so user knows the scan is running
    invoke_notify("scan_heartbeat", {
        "attempt":     attempt,
        "maxAttempts": max_attempts,
        "errors":      errors,
    })

    return {"found": False, "timeout": False, "attempts": attempt}