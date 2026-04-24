"""ZTW reconciler: converge AWS Organizations state with Zscaler Connector Portal.

Flow per add:
  1. Generate per-account externalId (UUID)
  2. Deploy CFN stack instance into target account via service-managed StackSet
     (deploys ZscalerTagDiscoveryRoleBasic with the externalId condition)
  3. Wait for StackSet operation to SUCCEED (role exists + is assumable)
  4. POST /ztw/api/v1/publicCloudInfo with the same externalId
  5. (optional) verify permissionStatus.assumeRole -> Allowed

Offboard = inverse: DELETE from OneAPI, then delete stack instance.

Opt-in gate: only ACTIVE accounts with tag {OPT_IN_TAG_KEY}={OPT_IN_TAG_VALUE}.
Core-OU accounts (Management, LogArchive, Audit) must NOT carry this tag.
"""
import json, os, time, uuid, logging, urllib.request, urllib.parse, urllib.error
import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

SECRET_ID   = os.environ["ZS_SECRET_ID"]
STACKSET    = os.environ["STACKSET_NAME"]
TARGET_REGION = os.environ.get("TARGET_REGION", "ap-southeast-2")
ZTW_REGION_ID = int(os.environ.get("ZTW_REGION_ID", "1178338"))     # AP_SOUTHEAST_2
ZTW_REGION_NAME = os.environ.get("ZTW_REGION_NAME", "AP_SOUTHEAST_2")
DRY_RUN     = os.environ.get("DRY_RUN", "true").lower() == "true"
TAG_KEY     = os.environ.get("OPT_IN_TAG_KEY", "zscaler-managed")
TAG_VAL     = os.environ.get("OPT_IN_TAG_VALUE", "true")
API_MIN_GAP = 1.5   # OneAPI: 1/SECOND limit, serialize with margin

_sm = boto3.client("secretsmanager")
_org = boto3.client("organizations")
_cfn = boto3.client("cloudformation")
_creds_cache = {}
_last_api_call = [0.0]
_root_id = [None]


def _org_root():
    if _root_id[0] is None:
        _root_id[0] = _org.list_roots()["Roots"][0]["Id"]
    return _root_id[0]


def _creds():
    if not _creds_cache:
        _creds_cache.update(json.loads(_sm.get_secret_value(SecretId=SECRET_ID)["SecretString"]))
    return _creds_cache


def _token():
    c = _creds()
    data = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": c["client_id"],
        "client_secret": c["client_secret"],
        "audience": "https://api.zscaler.com",
    }).encode()
    req = urllib.request.Request(f"https://{c['vanity']}/oauth2/v1/token", data=data, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())["access_token"]


def _api(method, path, token, body=None):
    gap = time.time() - _last_api_call[0]
    if gap < API_MIN_GAP:
        time.sleep(API_MIN_GAP - gap)
    url = f"https://api.zsapi.net{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            _last_api_call[0] = time.time()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        _last_api_call[0] = time.time()
        return e.code, e.read().decode()


def _opt_in(aid):
    try:
        tags = _org.list_tags_for_resource(ResourceId=aid).get("Tags", [])
        return any(t["Key"] == TAG_KEY and t["Value"] == TAG_VAL for t in tags)
    except Exception as e:
        log.warning("tag lookup failed for %s: %s", aid, e)
        return False


def _org_accounts():
    out = {}
    for page in _org.get_paginator("list_accounts").paginate():
        for a in page["Accounts"]:
            if a["Status"] == "ACTIVE":
                out[a["Id"]] = a
    return out


def _ztw_accounts(token):
    _, body = _api("GET", "/ztw/api/v1/publicCloudInfo", token)
    return {a["accountDetails"]["awsAccountId"]: a
            for a in (body or []) if a.get("cloudType") == "AWS"}


def _deploy_role(aid, ext_id):
    # Service-managed StackSets target OUs; use INTERSECTION to narrow to one account.
    # In production TSE, pass the specific Workloads-OU ID(s) via env var instead of root.
    op = _cfn.create_stack_instances(
        StackSetName=STACKSET,
        DeploymentTargets={
            "OrganizationalUnitIds": [_org_root()],
            "Accounts": [aid],
            "AccountFilterType": "INTERSECTION",
        },
        Regions=[TARGET_REGION],
        ParameterOverrides=[{"ParameterKey": "ExternalId", "ParameterValue": ext_id}],
        OperationPreferences={"MaxConcurrentCount": 1, "FailureToleranceCount": 0},
    )["OperationId"]
    log.info("stackset op %s dispatched for %s", op, aid)

    for i in range(30):
        time.sleep(10)
        s = _cfn.describe_stack_set_operation(StackSetName=STACKSET, OperationId=op)["StackSetOperation"]
        st = s["Status"]
        log.info("stackset op %s: %s (poll %d)", op, st, i + 1)
        if st == "SUCCEEDED":
            return True
        if st in ("FAILED", "STOPPED"):
            raise RuntimeError(f"StackSet op {op} {st}")
    raise TimeoutError(f"StackSet op {op} did not SUCCEED within 5 min")


def _delete_role(aid):
    try:
        _cfn.delete_stack_instances(
            StackSetName=STACKSET,
            DeploymentTargets={
                "OrganizationalUnitIds": [_org_root()],
                "Accounts": [aid],
                "AccountFilterType": "INTERSECTION",
            },
            Regions=[TARGET_REGION],
            RetainStacks=False,
            OperationPreferences={"MaxConcurrentCount": 1, "FailureToleranceCount": 0},
        )
        log.info("stackset delete dispatched for %s", aid)
    except _cfn.exceptions.StackInstanceNotFoundException:
        log.info("no stack instance for %s, skip", aid)


def _onboard(aid, name, token):
    ext_id = uuid.uuid4().hex
    log.info("onboard %s (%s) extId=%s", aid, name, ext_id)
    _deploy_role(aid, ext_id)
    payload = {
        "name": name, "cloudType": "AWS", "externalId": ext_id,
        "accountDetails": {
            "awsAccountId": aid,
            "awsRoleName": "ZscalerTagDiscoveryRoleBasic",
            "externalId": ext_id,
        },
        "supportedRegions": [{"id": ZTW_REGION_ID, "cloudType": "AWS", "name": ZTW_REGION_NAME}],
    }
    code, resp = _api("POST", "/ztw/api/v1/publicCloudInfo", token, payload)
    log.info("POST %d for %s: %s", code, aid, resp if code >= 300 else "ok")
    return code < 300


def _offboard(aid, ztw_rec, token):
    log.info("offboard %s (ztw id=%s)", aid, ztw_rec["id"])
    code, resp = _api("DELETE", f"/ztw/api/v1/publicCloudInfo/{ztw_rec['id']}", token)
    log.info("DELETE %d for %s: %s", code, aid, resp if code >= 300 else "ok")
    if code < 300:
        _delete_role(aid)
        return True
    return False


def lambda_handler(event, _ctx):
    trigger = event.get("source") or event.get("detail-type") or "manual"
    log.info("trigger: %s dry_run=%s", trigger, DRY_RUN)

    token = _token()
    org = _org_accounts()
    ztw = _ztw_accounts(token)

    tagged = {aid for aid in org if _opt_in(aid)}
    to_add    = tagged - set(ztw)
    to_remove = set(ztw) - tagged
    # only offboard accounts we manage (record name prefix guard — avoid touching
    # pre-existing manually-onboarded accounts)
    to_remove = {aid for aid in to_remove if ztw[aid]["name"].startswith(os.environ.get("MANAGED_PREFIX", "ZTW-"))}

    log.info("org=%d tagged=%d ztw=%d add=%d remove=%d",
             len(org), len(tagged), len(ztw), len(to_add), len(to_remove))

    added, removed, failed = [], [], []

    for aid in to_add:
        name = os.environ.get("MANAGED_PREFIX", "ZTW-") + org[aid]["Name"]
        if DRY_RUN:
            log.info("DRY_RUN add %s (%s)", aid, name)
            added.append(aid); continue
        try:
            if _onboard(aid, name, token):
                added.append(aid)
            else:
                failed.append(aid)
        except Exception as e:
            log.exception("onboard %s failed: %s", aid, e)
            failed.append(aid)

    for aid in to_remove:
        if DRY_RUN:
            log.info("DRY_RUN remove %s", aid)
            removed.append(aid); continue
        try:
            if _offboard(aid, ztw[aid], token):
                removed.append(aid)
            else:
                failed.append(aid)
        except Exception as e:
            log.exception("offboard %s failed: %s", aid, e)
            failed.append(aid)

    result = {"added": added, "removed": removed, "failed": failed, "dry_run": DRY_RUN, "trigger": trigger}
    log.info("result: %s", result)
    return result
