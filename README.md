# GCS → Eventarc → Cloud Function → BigQuery Demo

An event-driven pipeline that automatically loads CSV files into BigQuery the moment they land in a GCS bucket.

## Architecture

```
  ┌─────────────┐    object.finalized    ┌───────────┐    triggers    ┌──────────────────┐    load job    ┌───────────┐
  │  CSV File    │ ──────────────────────▶│  Eventarc │ ─────────────▶│  Cloud Function  │ ─────────────▶│  BigQuery │
  │  uploaded    │                        │  Trigger  │               │  (2nd Gen)       │               │  Table    │
  └─────────────┘                        └───────────┘               └──────────────────┘               └───────────┘
       GCS Bucket                                                     gcs-to-bq-loader                  eventarc_demo.sales
```

## Prerequisites

- **Google Cloud SDK** (`gcloud`, `gsutil`, `bq`) installed and authenticated
- A **GCP project** with billing enabled
- Sufficient permissions (Owner or Editor role recommended for the demo)

## Quick Start

### 1. Configure your Project ID

Edit the `PROJECT_ID` variable at the top of each script in `scripts/`:

```bash
PROJECT_ID="your-actual-project-id"
```

### 2. Set up infrastructure

```bash
chmod +x scripts/*.sh
./scripts/01_setup_infra.sh
```

This will:
- Enable required APIs (Cloud Functions, Eventarc, Storage, BigQuery, Cloud Run, Cloud Build)
- Create a GCS bucket: `gs://{PROJECT_ID}-eventarc-demo`
- Create a BigQuery dataset (`eventarc_demo`) and table (`sales`)
- Grant necessary IAM roles to service accounts
- Deploy the Cloud Function with an Eventarc trigger

### 3. Test the pipeline

```bash
./scripts/02_test_upload.sh
```

This uploads two sample CSV files and queries BigQuery to verify:
- **Batch 1**: 10 rows loaded
- **Batch 2**: 5 more rows appended (15 total)

### 4. Clean up

```bash
./scripts/03_cleanup.sh
```

Removes all resources created by the demo.

## How It Works

1. **A CSV file is uploaded** to the GCS bucket (manually or via `gsutil`)
2. **Eventarc detects** the `google.cloud.storage.object.v1.finalized` event
3. **The Cloud Function fires** and:
   - Validates the file is a CSV (skips non-CSV files)
   - Loads the CSV into a temporary BigQuery table
   - INSERTs rows from the temp table into the final table, adding:
     - `loaded_at` — timestamp of when the data was loaded
     - `source_file` — the GCS URI of the source file (for lineage tracking)
   - Cleans up the temp table
4. **Rows appear in BigQuery** within seconds

## Sample Data

| File | Rows | Description |
|------|------|-------------|
| `sales_batch_1.csv` | 10 | Initial batch of e-commerce orders |
| `sales_batch_2.csv` | 5 | Second batch to test incremental append |

## BigQuery Schema

| Column | Type | Description |
|--------|------|-------------|
| `order_id` | STRING | Unique order identifier |
| `product_name` | STRING | Product ordered |
| `quantity` | INTEGER | Units ordered |
| `unit_price` | FLOAT | Price per unit (USD) |
| `order_date` | DATE | Date of order |
| `customer_email` | STRING | Customer email |
| `region` | STRING | Geographic region |
| `loaded_at` | TIMESTAMP | When the row was loaded (auto-populated) |
| `source_file` | STRING | GCS URI of the source file (auto-populated) |

## Project Structure

```
gcs-eventarc-bq-demo/
├── README.md                     # This file
├── cloud_function/
│   ├── main.py                   # Cloud Function entry point
│   └── requirements.txt          # Python dependencies
├── sample_data/
│   ├── sales_batch_1.csv         # Test data (10 rows)
│   └── sales_batch_2.csv         # Test data (5 rows)
├── schema/
│   └── sales_schema.json         # BigQuery table schema
└── scripts/
    ├── 01_setup_infra.sh         # Create all GCP resources
    ├── 02_test_upload.sh         # Upload test data and verify
    └── 03_cleanup.sh             # Tear down all resources
```

## Troubleshooting

### "Permission denied" errors during setup
Make sure your `gcloud` account has Owner or Editor permissions on the project:
```bash
gcloud config get-value account
```

### Cloud Function doesn't fire after file upload
1. Check that the Eventarc trigger was created:
   ```bash
   gcloud eventarc triggers list --location=us-central1
   ```
2. Verify the Cloud Storage service agent has Pub/Sub Publisher role:
   ```bash
   PROJECT_NUMBER=$(gcloud projects describe YOUR_PROJECT --format="value(projectNumber)")
   gcloud projects get-iam-policy YOUR_PROJECT \
     --flatten="bindings[].members" \
     --filter="bindings.members:service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com"
   ```

### "API not enabled" errors
Re-run the API enable command:
```bash
gcloud services enable cloudfunctions.googleapis.com eventarc.googleapis.com storage.googleapis.com bigquery.googleapis.com run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com
```

### Checking function logs
```bash
gcloud functions logs read gcs-to-bq-loader --gen2 --region=us-central1 --limit=30
```

## Cost Estimate

This demo uses minimal resources and is well within free-tier limits:
- **Cloud Functions**: 2M free invocations/month
- **BigQuery**: 10 GB free storage, 1 TB free queries/month
- **GCS**: 5 GB free storage (Standard class)
- **Eventarc**: No additional charge (uses Pub/Sub under the hood)

Run `./scripts/03_cleanup.sh` when done to avoid any ongoing charges.
