#!/usr/bin/env python3
"""
generate_load.py — tagged SQL-usage load generator for the chargeback dashboard.

Runs UNEVEN query volumes against samples.bakehouse.sales_customers so the
Databricks Operating Cost dashboard lights up with per-tenant usage in the
system tables (system.billing.usage + system.query.history).

Two attribution methods are exercised:
  * Method A — warehouse-per-tenant. Each tenant has its own warehouse tagged
               custom_tags['tenant']=<name>. Attribution flows through billing;
               NO per-query tag is needed. This script just drives volume onto
               each per-tenant warehouse.
  * Method B — one SHARED warehouse. Every query carries query_tags['tenant'],
               set with `SET QUERY_TAGS['tenant']='<name>'` inside a persistent
               databricks-sql-connector session (one session per tenant so the
               SET sticks). The Statement Execution API is stateless per call and
               cannot carry a session SET — hence the connector.

This is a TEST / DEMO harness. It generates synthetic usage to test the
dashboard. It is NOT production and does not depend on the tenant_key_mapping
table (attribution here is purely tag-driven).

Auth: uses an existing Databricks CLI profile (`databricks auth token`).
Warehouse IDs come from --warehouses-env (written by provision_warehouses.sh)
or from explicit --*-wh flags.

Usage:
  python3 generate_load.py --profile <cli_profile>                 # uses warehouses.env
  python3 generate_load.py --profile <p> --carls-wh <id> --tims-wh <id> \
      --jeff-wh <id> --shared-wh <id>
  python3 generate_load.py --profile <p> --method A                # Method A only
  python3 generate_load.py --profile <p> --carls-a 60 --carls-b 30 # override counts
"""
import argparse, json, os, subprocess, sys, random

try:
    from databricks import sql
except ImportError:
    sys.exit("Missing dependency: pip install databricks-sql-connector")

TABLE = "samples.bakehouse.sales_customers"  # small (~300 rows) but universal in samples

# ---- query shapes: deliberately non-trivial (self-joins + aggregation) so each
# ---- serverless warehouse stays up long enough to register billable DBUs -------
def make_query(i):
    mode = i % 4
    if mode == 0:
        return (f"SELECT continent, country, gender, COUNT(*) n, "
                f"COUNT(DISTINCT city) cities, AVG(LENGTH(email_address)) avg_len "
                f"FROM {TABLE} GROUP BY continent, country, gender ORDER BY n DESC")
    if mode == 1:
        # self-join on state+gender inflates the row count well past 300
        return (f"SELECT a.country, a.state, COUNT(*) pairs, "
                f"COUNT(DISTINCT b.customerID) matched "
                f"FROM {TABLE} a JOIN {TABLE} b "
                f"ON a.state=b.state AND a.gender=b.gender "
                f"GROUP BY a.country, a.state ORDER BY pairs DESC")
    if mode == 2:
        return (f"SELECT state, COUNT(*) n, "
                f"PERCENTILE(postal_zip_code, 0.5) median_zip, "
                f"MIN(first_name) fn, MAX(last_name) ln "
                f"FROM {TABLE} GROUP BY state HAVING COUNT(*) > 0 ORDER BY n DESC")
    # windowed rank across a self-joined set
    return (f"SELECT country, city, cnt, "
            f"RANK() OVER (PARTITION BY country ORDER BY cnt DESC) rk FROM ("
            f"  SELECT a.country, a.city, COUNT(*) cnt FROM {TABLE} a "
            f"  JOIN {TABLE} b ON a.continent=b.continent "
            f"  GROUP BY a.country, a.city) t")


def get_token(profile):
    p = subprocess.run(["databricks", "auth", "token", "--profile", profile],
                       capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"Could not get token for profile {profile}: {p.stderr}")
    return json.loads(p.stdout)["access_token"]


def run_tenant(host, wid, token, tenant, count, tagmode):
    """Open ONE session; optionally SET QUERY_TAGS; run `count` queries."""
    http_path = f"/sql/1.0/warehouses/{wid}"
    conn = sql.connect(server_hostname=host, http_path=http_path, access_token=token)
    cur = conn.cursor()
    cur.execute("SET use_cached_result = false")
    if tagmode:
        cur.execute(f"SET QUERY_TAGS['tenant'] = '{tenant}'")
    ok = 0
    for i in range(count):
        try:
            cur.execute(make_query(i))
            cur.fetchall()
            ok += 1
        except Exception as e:
            print(f"    [{tenant}] query {i} ERR: {str(e)[:120]}")
    cur.close(); conn.close()
    tag = "query_tags['tenant']" if tagmode else "warehouse custom_tags"
    print(f"  {tenant:16} on {wid}: {ok}/{count} queries OK  (attr via {tag})")
    return ok


def load_env(path):
    env = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"')
    return env


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--profile", required=True, help="Databricks CLI profile")
    ap.add_argument("--host", help="workspace host (else derived from profile env file)")
    ap.add_argument("--warehouses-env", default=os.path.join(os.path.dirname(__file__), "warehouses.env"))
    ap.add_argument("--method", choices=["A", "B", "both"], default="both")
    # warehouse id overrides
    ap.add_argument("--carls-wh"); ap.add_argument("--tims-wh")
    ap.add_argument("--jeff-wh");  ap.add_argument("--shared-wh")
    # tenant names (parameterized)
    ap.add_argument("--carls-name", default="Carls Corner")
    ap.add_argument("--tims-name",  default="Tims Trailers")
    ap.add_argument("--jeff-name",  default="Jefferies Jobs")
    # per-tenant counts (UNEVEN: Carls heaviest -> Jefferies lightest)
    ap.add_argument("--carls-a", type=int, default=40)
    ap.add_argument("--tims-a",  type=int, default=20)
    ap.add_argument("--jeff-a",  type=int, default=8)
    ap.add_argument("--carls-b", type=int, default=25)
    ap.add_argument("--tims-b",  type=int, default=15)
    ap.add_argument("--jeff-b",  type=int, default=6)
    args = ap.parse_args()

    env = load_env(args.warehouses_env)
    host = args.host or env.get("HOST")
    if not host:
        sys.exit("No host: pass --host or provide HOST in warehouses.env")
    carls = args.carls_wh or env.get("CARLS_WH")
    tims  = args.tims_wh  or env.get("TIMS_WH")
    jeff  = args.jeff_wh  or env.get("JEFF_WH")
    shared = args.shared_wh or env.get("SHARED_WH")

    token = get_token(args.profile)
    print(f"Load target table: {TABLE}")

    if args.method in ("A", "both"):
        print("== Method A: warehouse-per-tenant (attribution via custom_tags['tenant']) ==")
        for wid, name, n in [(carls, args.carls_name, args.carls_a),
                             (tims, args.tims_name, args.tims_a),
                             (jeff, args.jeff_name, args.jeff_a)]:
            if not wid:
                print(f"  (skip {name}: no warehouse id)"); continue
            run_tenant(host, wid, token, name, n, tagmode=False)

    if args.method in ("B", "both"):
        print("== Method B: shared warehouse (attribution via query_tags['tenant']) ==")
        if not shared:
            print("  (skip: no shared warehouse id)")
        else:
            for name, n in [(args.carls_name, args.carls_b),
                            (args.tims_name, args.tims_b),
                            (args.jeff_name, args.jeff_b)]:
                run_tenant(host, shared, token, name, n, tagmode=True)

    print("Done. Query history ingests in ~10-15 min; billing on a multi-hour lag.")


if __name__ == "__main__":
    main()
