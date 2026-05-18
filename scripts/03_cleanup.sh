#!/usr/bin/env bash
# ============================================================================
# 03_cleanup.sh — Tear down all resources created by the demo
#
# Usage:
#   chmod +x scripts/03_cleanup.sh
#   ./scripts/03_cleanup.sh
# ============================================================================

set -euo pipefail

# ── CONFIGURATION — Must match 01_setup_infra.sh ──────────────────────────────
PROJECT_ID="your-project-id"          # <-- Replace with your GCP project ID
REGION="us-central1"
BUCKET_NAME="${PROJECT_ID}-eventarc-demo"
BQ_DATASET="eventarc_demo"
FUNCTION_NAME="gcs-to-bq-loader"
# ──────────────────────────────────────────────────────────────────────────────

echo "============================================"
echo "  🧹 Cleaning up Eventarc Demo Resources"
echo "============================================"
echo ""
echo "  This will delete:"
echo "    • Cloud Function: ${FUNCTION_NAME}"
echo "    • GCS Bucket:     gs://${BUCKET_NAME}"
echo "    • BigQuery Dataset: ${BQ_DATASET} (and all tables)"
echo ""

read -p "  Are you sure? (y/N): " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "  Aborted."
  exit 0
fi

echo ""

# ── 1. Delete Cloud Function ─────────────────────────────────────────────────
echo "🗑️  Deleting Cloud Function: ${FUNCTION_NAME}..."
gcloud functions delete "${FUNCTION_NAME}" \
  --gen2 \
  --region="${REGION}" \
  --quiet 2>/dev/null && echo "   ✅ Cloud Function deleted" || echo "   ⏭️  Cloud Function not found, skipping"

# ── 2. Delete GCS bucket ─────────────────────────────────────────────────────
echo ""
echo "🗑️  Deleting GCS bucket: gs://${BUCKET_NAME}..."
gsutil -m rm -r "gs://${BUCKET_NAME}" 2>/dev/null && echo "   ✅ Bucket deleted" || echo "   ⏭️  Bucket not found, skipping"

# ── 3. Delete BigQuery dataset ────────────────────────────────────────────────
echo ""
echo "🗑️  Deleting BigQuery dataset: ${BQ_DATASET}..."
bq rm -r -f --project_id="${PROJECT_ID}" "${BQ_DATASET}" 2>/dev/null && echo "   ✅ Dataset deleted" || echo "   ⏭️  Dataset not found, skipping"

# ── 4. Note about IAM bindings ────────────────────────────────────────────────
echo ""
echo "ℹ️  Note: IAM role bindings were NOT removed."
echo "   The following roles were granted during setup:"
echo "     • roles/eventarc.eventReceiver  (Compute Engine SA)"
echo "     • roles/run.invoker             (Compute Engine SA)"
echo "     • roles/pubsub.publisher        (GCS service agent)"
echo "   These are generally safe to leave in place."
echo "   To remove them manually, use:"
echo "     gcloud projects remove-iam-policy-binding ${PROJECT_ID} \\"
echo "       --member='serviceAccount:...' --role='roles/...'"

echo ""
echo "============================================"
echo "  ✅ Cleanup complete!"
echo "============================================"
echo ""
