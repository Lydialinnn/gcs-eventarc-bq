#!/usr/bin/env bash
# ============================================================================
# 01_setup_infra.sh — Provision all GCP resources for the Eventarc demo
#
# Usage:
#   chmod +x scripts/01_setup_infra.sh
#   ./scripts/01_setup_infra.sh
# ============================================================================

set -euo pipefail

# ── CONFIGURATION — Edit these values ─────────────────────────────────────────
PROJECT_ID="valor-sales"          # <-- Replace with your GCP project ID
REGION="northamerica-northeast2"
BUCKET_NAME="${PROJECT_ID}-eventarc-demo"
BQ_DATASET="eventarc_demo"
BQ_TABLE="sales"
FUNCTION_NAME="gcs-to-bq-loader"
# ──────────────────────────────────────────────────────────────────────────────

echo "============================================"
echo "  GCS → Eventarc → Cloud Function → BigQuery"
echo "  Infrastructure Setup"
echo "============================================"
echo ""
echo "  Project : ${PROJECT_ID}"
echo "  Region  : ${REGION}"
echo "  Bucket  : ${BUCKET_NAME}"
echo "  Dataset : ${BQ_DATASET}.${BQ_TABLE}"
echo ""

# ── 0. Set the active project ─────────────────────────────────────────────────
echo "🔧 Setting active project..."
gcloud config set project "${PROJECT_ID}"

# ── 1. Enable required APIs ───────────────────────────────────────────────────
echo ""
echo "🔌 Enabling required APIs..."
gcloud services enable \
  cloudfunctions.googleapis.com \
  eventarc.googleapis.com \
  storage.googleapis.com \
  bigquery.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  --quiet

echo "   ✅ APIs enabled"

# ── 2. Create GCS bucket ──────────────────────────────────────────────────────
echo ""
echo "🪣 Creating GCS bucket: gs://${BUCKET_NAME}"
if gsutil ls -b "gs://${BUCKET_NAME}" &>/dev/null; then
  echo "   ⏭️  Bucket already exists, skipping"
else
  gsutil mb -l "${REGION}" -p "${PROJECT_ID}" "gs://${BUCKET_NAME}"
  echo "   ✅ Bucket created"
fi

# ── 3. Create BigQuery dataset and table ──────────────────────────────────────
echo ""
echo "📊 Creating BigQuery dataset: ${BQ_DATASET}"
bq --project_id="${PROJECT_ID}" mk \
  --dataset \
  --location="${REGION}" \
  --description="Eventarc demo dataset" \
  "${PROJECT_ID}:${BQ_DATASET}" 2>/dev/null || echo "   ⏭️  Dataset already exists, skipping"

echo "📊 Creating BigQuery table: ${BQ_DATASET}.${BQ_TABLE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE="${SCRIPT_DIR}/../schema/sales_schema.json"

bq --project_id="${PROJECT_ID}" mk \
  --table \
  --description="Sales data loaded from GCS via Eventarc" \
  "${PROJECT_ID}:${BQ_DATASET}.${BQ_TABLE}" \
  "${SCHEMA_FILE}" 2>/dev/null || echo "   ⏭️  Table already exists, skipping"

echo "   ✅ BigQuery dataset and table ready"

# ── 4. Grant IAM roles to the default Compute Engine service account ──────────
echo ""
echo "🔐 Configuring IAM permissions..."

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# Grant Eventarc Event Receiver role
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${COMPUTE_SA}" \
  --role="roles/eventarc.eventReceiver" \
  --quiet > /dev/null 2>&1
echo "   ✅ Granted roles/eventarc.eventReceiver to ${COMPUTE_SA}"

# Grant Cloud Run Invoker role
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${COMPUTE_SA}" \
  --role="roles/run.invoker" \
  --quiet > /dev/null 2>&1
echo "   ✅ Granted roles/run.invoker to ${COMPUTE_SA}"

# Grant Cloud Storage service agent the Pub/Sub Publisher role
# This is REQUIRED for Eventarc to receive GCS notifications
GCS_SA="service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GCS_SA}" \
  --role="roles/pubsub.publisher" \
  --quiet > /dev/null 2>&1
echo "   ✅ Granted roles/pubsub.publisher to GCS service agent"

# ── 5. Deploy Cloud Function (2nd gen) ────────────────────────────────────────
echo ""
echo "🚀 Deploying Cloud Function: ${FUNCTION_NAME}"
echo "   This may take 2-3 minutes..."

FUNCTION_DIR="${SCRIPT_DIR}/../cloud_function"

gcloud functions deploy "${FUNCTION_NAME}" \
  --gen2 \
  --region="${REGION}" \
  --runtime=python312 \
  --source="${FUNCTION_DIR}" \
  --entry-point=gcs_to_bq_loader \
  --memory=256Mi \
  --timeout=120s \
  --trigger-event-filters="type=google.cloud.storage.object.v1.finalized" \
  --trigger-event-filters="bucket=${BUCKET_NAME}" \
  --set-env-vars="GCP_PROJECT=${PROJECT_ID},BQ_DATASET=${BQ_DATASET},BQ_TABLE=${BQ_TABLE}" \
  --quiet

echo "   ✅ Cloud Function deployed"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  ✅ Setup complete!"
echo "============================================"
echo ""
echo "  Next steps:"
echo "    1. Run: ./scripts/02_test_upload.sh"
echo "    2. Or manually upload a CSV:"
echo "       gsutil cp sample_data/sales_batch_1.csv gs://${BUCKET_NAME}/"
echo ""
