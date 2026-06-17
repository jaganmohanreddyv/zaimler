"""
dashboard.py — GPU Capacity Block Pipeline Live Dashboard
Read-only. All decisions are made through email links only.
Run: streamlit run dashboard.py
"""

import streamlit as st
import boto3
import json
import os
from datetime import datetime, timezone

# ── Load config.env ───────────────────────────────────────────────────────────
def load_config():
    cfg = {}
    config_path = os.path.join(os.path.dirname(__file__), "config.env")
    if os.path.exists(config_path):
        with open(config_path, "r") as f:
            for line in f:
                line = line.strip().replace("\r", "")
                if "=" in line and not line.startswith("#"):
                    key, _, val = line.partition("=")
                    cfg[key.strip()] = val.strip().strip('"')
    return cfg

cfg = load_config()

AWS_REGION     = cfg.get("AWS_REGION", "us-east-1")
AWS_ACCOUNT_ID = cfg.get("AWS_ACCOUNT_ID", "")
AWS_PROFILE    = cfg.get("AWS_PROFILE", "") or None
SM_ARN         = cfg.get("WATCHER_STATE_MACHINE_ARN", "")
DYNAMO_TABLE   = cfg.get("WATCHER_DYNAMODB_TABLE", "")
ALERT_EMAIL    = cfg.get("ALERT_EMAIL", "")
INSTANCE_TYPES = cfg.get("INSTANCE_TYPES", "")
REGIONS        = cfg.get("REGIONS", "")
AZS            = cfg.get("AVAILABILITY_ZONES", "")

# ── AWS clients ───────────────────────────────────────────────────────────────
session = boto3.Session(profile_name=AWS_PROFILE, region_name=AWS_REGION)
sfn     = session.client("stepfunctions")
dynamo  = session.resource("dynamodb")
logs    = session.client("logs")
ssm     = session.client("ssm")

# ── Page config ───────────────────────────────────────────────────────────────
st.set_page_config(
    page_title="GPU Capacity Pipeline",
    page_icon="🖥️",
    layout="wide",
    initial_sidebar_state="expanded",
)

st.title("🖥️ GPU Capacity Block Pipeline")
st.caption("Read-only dashboard — all decisions are made through email links only")

# ── Auto-refresh ──────────────────────────────────────────────────────────────
try:
    from streamlit_autorefresh import st_autorefresh
    st_autorefresh(interval=30_000, key="autorefresh")
except ImportError:
    pass

# ── Helpers ───────────────────────────────────────────────────────────────────
def ago(ts_str: str) -> str:
    if not ts_str:
        return "—"
    try:
        ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        diff = datetime.now(timezone.utc) - ts
        secs = int(diff.total_seconds())
        if secs < 60:    return f"{secs}s ago"
        if secs < 3600:  return f"{secs//60}m ago"
        if secs < 86400: return f"{secs//3600}h {(secs%3600)//60}m ago"
        return f"{secs//86400}d ago"
    except Exception:
        return ts_str

def safe_get(d, *keys, default="—"):
    for k in keys:
        if isinstance(d, dict):
            d = d.get(k, default)
        else:
            return default
    return d if d is not None else default

# ── Sidebar — pipeline selector ───────────────────────────────────────────────
st.sidebar.header("Pipeline run")

@st.cache_data(ttl=60)
def list_state_machines():
    try:
        resp = sfn.list_state_machines(maxResults=20)
        return [
            sm for sm in resp.get("stateMachines", [])
            if "gpu-capacity-pipeline" in sm["name"]
        ]
    except Exception:
        return []

machines = list_state_machines()
machine_names = [sm["name"] for sm in machines]

if not machine_names:
    st.sidebar.warning("No gpu-capacity-pipeline state machines found.")
    selected_sm_name = None
    selected_sm_arn  = None
else:
    selected_sm_name = st.sidebar.selectbox(
        "State machine", machine_names, index=0
    )
    selected_sm_arn = next(
        (sm["stateMachineArn"] for sm in machines if sm["name"] == selected_sm_name),
        None
    )

# Derive pipeline run ID and table name from state machine name
if selected_sm_name:
    run_id     = selected_sm_name.replace("gpu-capacity-pipeline-", "")
    table_name = f"gpu-watcher-state-{run_id}"
    ssm_prefix = f"/gpu-capacity-pipeline/{run_id}"
else:
    run_id = table_name = ssm_prefix = None

st.sidebar.markdown("---")
st.sidebar.caption(f"Account: `{AWS_ACCOUNT_ID}`")
st.sidebar.caption(f"Region: `{AWS_REGION}`")
st.sidebar.caption(f"Alert email: `{ALERT_EMAIL}`")
st.sidebar.caption(f"Instance: `{INSTANCE_TYPES}`")

# ── Main content ──────────────────────────────────────────────────────────────
if not selected_sm_arn:
    st.info("No running pipeline found. Run `bash main.sh` to start one.")
    st.stop()

# ── Row 1: execution status ───────────────────────────────────────────────────
st.subheader("Execution status")

@st.cache_data(ttl=15)
def get_executions(sm_arn):
    try:
        resp = sfn.list_executions(stateMachineArn=sm_arn, maxResults=5)
        return resp.get("executions", [])
    except Exception:
        return []

executions = get_executions(selected_sm_arn)
latest_exec = executions[0] if executions else {}
exec_status = latest_exec.get("status", "UNKNOWN")

status_color = {
    "RUNNING":   "🟢",
    "SUCCEEDED": "✅",
    "FAILED":    "🔴",
    "ABORTED":   "🟠",
    "TIMED_OUT": "🟡",
}.get(exec_status, "⚪")

col1, col2, col3, col4 = st.columns(4)
col1.metric("Execution", f"{status_color} {exec_status}")
col2.metric("Pipeline run", run_id or "—")

start_ts = latest_exec.get("startDate")
if start_ts:
    if hasattr(start_ts, "isoformat"):
        start_str = start_ts.isoformat()
    else:
        start_str = str(start_ts)
    col3.metric("Started", ago(start_str))
else:
    col3.metric("Started", "—")

col4.metric("State machine", selected_sm_name.split("-pipeline-")[-1])

# ── Row 2: watcher state from DynamoDB ───────────────────────────────────────
st.subheader("Watcher state")

@st.cache_data(ttl=15)
def get_watcher_state(tbl_name):
    try:
        table = dynamo.Table(tbl_name)
        resp  = table.get_item(Key={"pk": "watcher-state"})
        return resp.get("Item", {})
    except Exception as e:
        return {"error": str(e)}

state = get_watcher_state(table_name)

if "error" in state:
    st.error(f"DynamoDB error: {state['error']}")
else:
    attempt      = int(state.get("attemptCount", 0))
    max_attempts = int(state.get("maxAttempts", 192))
    max_hours    = int(state.get("maxHours", 48))
    watcher_status = state.get("status", "—")
    last_checked   = str(state.get("lastChecked", ""))
    start_time_str = str(state.get("startTime", ""))

    # Progress bar
    progress = min(attempt / max_attempts, 1.0) if max_attempts > 0 else 0
    mins_remaining = (max_attempts - attempt) * 15
    hours_remaining = mins_remaining // 60
    mins_rem_disp   = mins_remaining % 60

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Attempts", f"{attempt} / {max_attempts}")
    c2.metric("Watcher status", watcher_status.upper())
    c3.metric("Last scan", ago(last_checked))
    c4.metric("Est. time remaining", f"{hours_remaining}h {mins_rem_disp}m")

    st.progress(progress, text=f"{attempt}/{max_attempts} scans complete ({progress*100:.1f}%)")

    # Last result
    last_result_raw = state.get("lastResult", "")
    if last_result_raw:
        try:
            lr = json.loads(str(last_result_raw))
            found_count = lr.get("found", 0)
            error_count = lr.get("errors", 0)
            if found_count > 0:
                st.success(f"Last scan: {found_count} offering(s) found!")
            elif error_count > 0:
                st.warning(f"Last scan: nothing found, {error_count} API error(s) — this is normal for unsupported instance types")
            else:
                st.info("Last scan: no capacity found — continuing to watch")
        except Exception:
            pass

# ── Row 3: scan config ────────────────────────────────────────────────────────
st.subheader("Scan configuration")

@st.cache_data(ttl=60)
def get_ssm_params(prefix):
    try:
        paginator = ssm.get_paginator("get_parameters_by_path")
        params = {}
        for page in paginator.paginate(Path=prefix, Recursive=True):
            for p in page["Parameters"]:
                key = p["Name"].replace(prefix + "/", "")
                params[key] = p["Value"]
        return params
    except Exception as e:
        return {"error": str(e)}

ssm_params = get_ssm_params(ssm_prefix) if ssm_prefix else {}

if "error" not in ssm_params:
    sc1, sc2, sc3 = st.columns(3)
    sc1.info(f"**Combinations**\n\n`{ssm_params.get('combinations', INSTANCE_TYPES)}`")
    sc2.info(f"**Instance count**\n\n`{ssm_params.get('instance-count', '1')}`")
    sc3.info(f"**Duration**\n\n`{ssm_params.get('duration-days', '—')} days`")

    sc4, sc5, sc6 = st.columns(3)
    sc4.info(f"**Retry interval**\n\n`{ssm_params.get('retry-mins', '15')} minutes`")
    sc5.info(f"**Max window**\n\n`{ssm_params.get('max-hours', '48')} hours`")
    sc6.info(f"**Alert email**\n\n`{ssm_params.get('alert-email', ALERT_EMAIL)}`")

# ── Row 4: CloudWatch logs ─────────────────────────────────────────────────────
st.subheader("Latest discovery logs")

@st.cache_data(ttl=20)
def get_recent_logs(run_id_str):
    log_group = f"/aws/lambda/gpu-watcher-discovery-{run_id_str}"
    try:
        resp = logs.filter_log_events(
            logGroupName=log_group,
            limit=30,
        )
        events = resp.get("events", [])
        return [e["message"].strip() for e in events if e["message"].strip()]
    except Exception as e:
        return [f"Could not read logs: {e}"]

if run_id:
    log_lines = get_recent_logs(run_id)
    if log_lines:
        log_text = "\n".join(log_lines[-25:])
        st.code(log_text, language="text")
    else:
        st.info("No logs yet — Lambda has not been invoked yet or logs were cleaned up.")

# ── Row 5: infrastructure resources ──────────────────────────────────────────
with st.expander("Permanent infrastructure (aws_check_create.sh resources)"):
    infra = {
        "Key pair":          cfg.get("KEY_PAIR_NAME",         "—"),
        "Subnet":            cfg.get("SUBNET_ID",             "—"),
        "Security group":    cfg.get("SECURITY_GROUP_IDS",    "—"),
        "Placement group":   cfg.get("PLACEMENT_GROUP_NAME",  "—"),
        "IAM profile":       cfg.get("IAM_INSTANCE_PROFILE",  "—"),
        "Launch template":   cfg.get("LAUNCH_TEMPLATE_NAME",  "—"),
        "Launch template ID":cfg.get("LAUNCH_TEMPLATE_ID",    "—"),
        "SNS topic ARN":     cfg.get("SNS_TOPIC_ARN",         "—"),
    }
    for k, v in infra.items():
        c1, c2 = st.columns([1, 3])
        c1.write(f"**{k}**")
        c2.code(v)

# ── Row 6: watcher AWS resources ──────────────────────────────────────────────
with st.expander("Watcher services (temporary — deleted on exit)"):
    watcher = {
        "State machine ARN":  selected_sm_arn or "—",
        "DynamoDB table":     table_name or "—",
        "API Gateway URL":    ssm_params.get("api-gateway-url", cfg.get("WATCHER_API_GATEWAY_URL", "—")),
        "SSM prefix":         ssm_prefix or "—",
        "Pipeline run ID":    run_id or "—",
    }
    for k, v in watcher.items():
        c1, c2 = st.columns([1, 3])
        c1.write(f"**{k}**")
        c2.code(v)

# ── Footer ─────────────────────────────────────────────────────────────────────
st.markdown("---")
st.caption(
    "Dashboard auto-refreshes every 30 seconds. "
    "All pipeline decisions (PROCEED / CONFIRM PURCHASE / CANCEL) are made through email links only. "
    "This dashboard is read-only."
)