#!/usr/bin/env bash
# ============================================================================
# 02_test_upload.sh — Upload sample data to trigger the pipeline
#
# Usage:
#   chmod +x scripts/02_test_upload.sh
#   ./scripts/02_test_upload.sh
# ============================================================================

set -euo pipefail

# ── CONFIGURATION — Must match 01_setup_infra.sh ──────────────────────────────
PROJECT_ID="your-project-id"          # <-- Replace with your GCP project ID
BUCKET_NAME="${PROJECT_ID}-eventarc-demo"
BQ_DATASET="eventarc_demo"
BQ_TABLE="sales"
FUNCTION_NAME="gcs-to-bq-loader"
REGION="us-central1"
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../sample_data"

echo "============================================"
echo "  Testing the Eventarc Pipeline"
echo "============================================"
echo ""

# ── Test 1: Upload batch 1 ────────────────────────────────────────────────────
echo "📤 Uploading sales_batch_1.csv (10 rows)..."
gsutil cp "${DATA_DIR}/sales_batch_1.csv" "gs://${BUCKET_NAME}/"

echo "⏳ Waiting 20 seconds for the Cloud Function to process..."
sleep 20

echo ""
echo "📊 Querying BigQuery for results..."
echo "---"
bq query --use_legacy_sql=false --format=prettyjson \
  "SELECT
     COUNT(*) AS total_rows,
     COUNT(DISTINCT source_file) AS files_loaded,
     MIN(loaded_at) AS earliest_load,
     MAX(loaded_at) AS latest_load
   FROM \`${PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE}\`"
echo "---"

echo ""
echo "📋 Sample rows:"
bq query --use_legacy_sql=false --format=pretty \
  "SELECT order_id, product_name, quantity, unit_price, region, source_file
   FROM \`${PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE}\`
   ORDER BY order_id
   LIMIT 5"

# ── Test 2: Upload batch 2 (incremental) ─────────────────────────────────────
echo ""
echo "============================================"
echo "  Testing Incremental Load (Batch 2)"
echo "============================================"
echo ""

echo "📤 Uploading sales_batch_2.csv (5 rows)..."
gsutil cp "${DATA_DIR}/sales_batch_2.csv" "gs://${BUCKET_NAME}/"

echo "⏳ Waiting 20 seconds for the Cloud Function to process..."
sleep 20

echo ""
echo "📊 Querying BigQuery — should now show 15 total rows..."
echo "---"
bq query --use_legacy_sql=false --format=prettyjson \
  "SELECT
     COUNT(*) AS total_rows,
     COUNT(DISTINCT source_file) AS files_loaded,
     MIN(loaded_at) AS earliest_load,
     MAX(loaded_at) AS latest_load
   FROM \`${PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE}\`"
echo "---"

echo ""
echo "📋 Rows grouped by source file:"
bq query --use_legacy_sql=false --format=pretty \
  "SELECT
     source_file,
     COUNT(*) AS row_count,
     MIN(order_date) AS min_date,
     MAX(order_date) AS max_date
   FROM \`${PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE}\`
   GROUP BY source_file
   ORDER BY source_file"

# ── Test 3: Upload batch 3 (MERGE — updates + new rows) ──────────────────────
echo ""
echo "============================================"
echo "  Testing MERGE Upsert (Batch 3)"
echo "============================================"
echo ""
echo "  Batch 3 contains:"
echo "    • 3 UPDATED orders: ORD-1002, ORD-1005, ORD-1008 (changed name/qty/price)"
echo "    • 2 NEW orders: ORD-1016, ORD-1017"
echo ""
echo "  Expected: total rows should be 17 (15 + 2 new), NOT 20 (15 + 5)"
echo "  because the 3 existing orders get UPDATED, not duplicated."
echo ""

echo "📤 Uploading sales_batch_3_updates.csv (3 updates + 2 new)..."
gsutil cp "${DATA_DIR}/sales_batch_3_updates.csv" "gs://${BUCKET_NAME}/"

echo "⏳ Waiting 20 seconds for the Cloud Function to process..."
sleep 20

echo ""
echo "📊 Querying BigQuery — should show 17 total rows (not 20)..."
echo "---"
bq query --use_legacy_sql=false --format=prettyjson \
  "SELECT
     COUNT(*) AS total_rows,
     COUNT(DISTINCT source_file) AS files_loaded,
     MIN(loaded_at) AS earliest_load,
     MAX(loaded_at) AS latest_load
   FROM \`${PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE}\`"
echo "---"

echo ""
echo "📋 Verify UPDATED rows (should show new values from batch 3):"
bq query --use_legacy_sql=false --format=pretty \
  "SELECT order_id, product_name, quantity, unit_price, region, source_file
   FROM \`${PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE}\`
   WHERE order_id IN ('ORD-1002', 'ORD-1005', 'ORD-1008')
   ORDER BY order_id"

echo ""
echo "📋 Verify NEW rows (should exist as new entries):"
bq query --use_legacy_sql=false --format=pretty \
  "SELECT order_id, product_name, quantity, unit_price, region, source_file
   FROM \`${PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE}\`
   WHERE order_id IN ('ORD-1016', 'ORD-1017')
   ORDER BY order_id"

echo ""
echo "📋 Rows grouped by source file:"
bq query --use_legacy_sql=false --format=pretty \
  "SELECT
     source_file,
     COUNT(*) AS row_count,
     MIN(order_date) AS min_date,
     MAX(order_date) AS max_date
   FROM \`${PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE}\`
   GROUP BY source_file
   ORDER BY source_file"

# ── Check function logs ──────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Cloud Function Logs (last 30 entries)"
echo "============================================"
echo ""
gcloud functions logs read "${FUNCTION_NAME}" \
  --gen2 \
  --region="${REGION}" \
  --limit=30

echo ""
echo "✅ Test complete!"
echo ""

