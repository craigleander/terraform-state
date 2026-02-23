#!/usr/bin/env bash
# TAP daily usage report using gcloud only. POSTs JSON to webhook.
# Intent: see INTENT-DAILY-USAGE.md. No billing API required.
# Usage: PROJECT_ID=leander-test-471809 REGION=asia-south1 ./daily_usage_report_gcloud.sh

set -e
PROJECT_ID="${GCP_PROJECT_ID:-$PROJECT_ID}"
PROJECT_ID="${PROJECT_ID:-leander-test-471809}"
REGION="${GCP_REGION:-$REGION}"
REGION="${REGION:-asia-south1}"
WEBHOOK_URL="${WEBHOOK_URL:-https://aiden.stackgen.com/api/v1/tasks/46548a94-f7a8-4c22-a361-9b794b075db4/webhook}"
REPORT_JSON=""

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# GKE: clusters in region (name, location, then node-pools for each)
gke_clusters() {
  gcloud container clusters list --project="$PROJECT_ID" --format=json --filter="location:$REGION" 2>/dev/null || echo "[]"
}
gke_node_pools() {
  local cluster="$1"
  local loc="$2"
  if [[ "$loc" == *-*-*-* ]]; then
    gcloud container node-pools list --project="$PROJECT_ID" --cluster="$cluster" --region="$REGION" --format=json 2>/dev/null || echo "[]"
  else
    gcloud container node-pools list --project="$PROJECT_ID" --cluster="$cluster" --region="$REGION" --format=json 2>/dev/null || echo "[]"
  fi
}

# Cloud SQL
sql_list() {
  gcloud sql instances list --project="$PROJECT_ID" --format=json 2>/dev/null || echo '{"items":[]}'
}

# Redis
redis_list() {
  gcloud redis instances list --project="$PROJECT_ID" --region="$REGION" --format=json 2>/dev/null || echo "[]"
}

# GCS buckets
gcs_list() {
  gcloud storage buckets list --project="$PROJECT_ID" --format=json 2>/dev/null || echo "[]"
}

# Cloud Build (last 100)
build_list() {
  gcloud builds list --project="$PROJECT_ID" --limit=100 --format=json 2>/dev/null || echo "[]"
}

# Pub/Sub
pubsub_topics() {
  gcloud pubsub topics list --project="$PROJECT_ID" --format=json 2>/dev/null || echo "[]"
}
pubsub_subs() {
  gcloud pubsub subscriptions list --project="$PROJECT_ID" --format=json 2>/dev/null || echo "[]"
}

# Artifact Registry
ar_list() {
  gcloud artifacts repositories list --project="$PROJECT_ID" --location="$REGION" --format=json 2>/dev/null || echo "[]"
}

# Build report JSON with jq (requires jq)
build_report() {
  local gke_raw sql_raw redis_raw gcs_raw build_raw topics_raw subs_raw ar_raw
  gke_raw=$(gke_clusters)
  sql_raw=$(sql_list)
  redis_raw=$(redis_list)
  gcs_raw=$(gcs_list)
  build_raw=$(build_list)
  topics_raw=$(pubsub_topics)
  subs_raw=$(pubsub_subs)
  ar_raw=$(ar_list)

  jq -n \
    --arg proj "$PROJECT_ID" \
    --arg reg "$REGION" \
    --arg ts "$(ts)" \
    --argjson gke "$gke_raw" \
    --argjson sql "$sql_raw" \
    --argjson redis "$redis_raw" \
    --argjson gcs "$gcs_raw" \
    --argjson builds "$build_raw" \
    --argjson topics "$topics_raw" \
    --argjson subs "$subs_raw" \
    --argjson ar "$ar_raw" \
    '{
      task: "TAP daily usage & capacity report",
      project_id: $proj,
      region: $reg,
      timestamp: $ts,
      purpose: "Cost alert / capacity review / ad hoc — gcloud only; no billing API",
      gke: { clusters: $gke, total_nodes: ([$gke[]? | .currentNodeCount? // 0] | add // 0) },
      cloud_sql: { raw: $sql, instance_count: (if ($sql | type) == "object" and ($sql | has("items")) then ($sql.items | length) elif ($sql | type) == "array" then ($sql | length) else 0 end) },
      redis: { instances: $redis, count: ($redis | length) },
      gcs: { buckets: $gcs, bucket_count: ($gcs | length) },
      cloud_build: { builds_sample: $builds, build_count: ($builds | length) },
      pubsub: { topics: $topics, subscriptions: $subs, topic_count: ($topics | length), subscription_count: ($subs | length) },
      artifact_registry: { repositories: $ar, repo_count: ($ar | length) },
      summary: {
        total_nodes: ([$gke[]? | .currentNodeCount? // 0] | add // 0),
        sql_instances: (if ($sql | type) == "object" and ($sql | has("items")) then ($sql.items | length) elif ($sql | type) == "array" then ($sql | length) else 0 end),
        redis_instances: ($redis | length),
        gcs_buckets: ($gcs | length),
        builds_in_sample: ($builds | length),
        pubsub_topics: ($topics | length),
        artifact_repos: ($ar | length)
      }
    }'
}

REPORT_JSON=$(build_report)
echo "$REPORT_JSON" | jq .
