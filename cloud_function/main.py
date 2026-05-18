"""
Cloud Function (2nd Gen) — GCS to BigQuery Loader

Triggered by Eventarc when a new object is finalized (uploaded) in a GCS bucket.
Loads CSV files into a BigQuery table using a load job, then stamps each row
with metadata (source file URI and load timestamp).
"""

import os
import json
import functions_framework
from datetime import datetime, timezone

from google.cloud import bigquery
from cloudevents.http import CloudEvent


# ── Configuration from environment variables ──────────────────────────────────
PROJECT_ID = os.environ.get("GCP_PROJECT")
BQ_DATASET = os.environ.get("BQ_DATASET", "eventarc_demo")
BQ_TABLE = os.environ.get("BQ_TABLE", "sales")


@functions_framework.cloud_event
def gcs_to_bq_loader(cloud_event: CloudEvent):
    """
    Entry point for the Cloud Function.

    Receives a CloudEvent from Eventarc when an object is finalized in GCS.
    If the object is a CSV file, it loads it into BigQuery and stamps
    metadata columns (loaded_at, source_file).
    """

    # ── 1. Extract event data ─────────────────────────────────────────────
    data = cloud_event.data
    bucket_name = data["bucket"]
    file_name = data["name"]
    gcs_uri = f"gs://{bucket_name}/{file_name}"

    print(f"📥 Event received: new file '{file_name}' in bucket '{bucket_name}'")
    print(f"   Content type: {data.get('contentType', 'unknown')}")
    print(f"   Size: {data.get('size', 'unknown')} bytes")

    # ── 2. Guard: only process CSV files ──────────────────────────────────
    if not file_name.lower().endswith(".csv"):
        print(f"⏭️  Skipping non-CSV file: {file_name}")
        return "Skipped — not a CSV file", 200

    # Skip directory markers / zero-byte objects
    if file_name.endswith("/"):
        print(f"⏭️  Skipping directory marker: {file_name}")
        return "Skipped — directory marker", 200

    # ── 3. Configure BigQuery load job ────────────────────────────────────
    client = bigquery.Client(project=PROJECT_ID)
    table_ref = f"{PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}"

    # We load into a temp table first (without metadata columns),
    # then INSERT into the final table with metadata columns added.
    # This approach keeps the CSV schema clean (no need for loaded_at/source_file in the CSV).

    temp_table_id = f"{PROJECT_ID}.{BQ_DATASET}._temp_load_{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}"

    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.CSV,
        skip_leading_rows=1,                          # Skip CSV header
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        autodetect=False,
        schema=[
            bigquery.SchemaField("order_id", "STRING", mode="REQUIRED"),
            bigquery.SchemaField("product_name", "STRING"),
            bigquery.SchemaField("quantity", "INTEGER"),
            bigquery.SchemaField("unit_price", "FLOAT"),
            bigquery.SchemaField("order_date", "DATE"),
            bigquery.SchemaField("customer_email", "STRING"),
            bigquery.SchemaField("region", "STRING"),
        ],
    )

    print(f"🔄 Starting BigQuery load job...")
    print(f"   Source : {gcs_uri}")
    print(f"   Temp   : {temp_table_id}")
    print(f"   Target : {table_ref}")

    # ── 4. Execute the load job ───────────────────────────────────────────
    try:
        load_job = client.load_table_from_uri(
            gcs_uri,
            temp_table_id,
            job_config=job_config,
        )

        # Wait for the job to complete
        load_job.result()

        print(f"✅ Load job completed: {load_job.output_rows} rows loaded into temp table")

        if load_job.errors:
            print(f"⚠️  Load job had errors: {json.dumps(load_job.errors, indent=2)}")

    except Exception as e:
        print(f"❌ Load job failed: {str(e)}")
        # Clean up temp table if it was partially created
        _cleanup_temp_table(client, temp_table_id)
        raise

    # ── 5. MERGE into final table (upsert on order_id) ───────────────────
    try:
        now_utc = datetime.now(timezone.utc).isoformat()

        merge_query = f"""
            MERGE INTO `{table_ref}` T
            USING (
                SELECT
                    order_id,
                    product_name,
                    quantity,
                    unit_price,
                    order_date,
                    customer_email,
                    region,
                    TIMESTAMP('{now_utc}') AS loaded_at,
                    '{gcs_uri}' AS source_file
                FROM `{temp_table_id}`
            ) S
            ON T.order_id = S.order_id

            -- Existing order_id → update all fields with latest values
            WHEN MATCHED THEN UPDATE SET
                T.product_name = S.product_name,
                T.quantity = S.quantity,
                T.unit_price = S.unit_price,
                T.order_date = S.order_date,
                T.customer_email = S.customer_email,
                T.region = S.region,
                T.loaded_at = S.loaded_at,
                T.source_file = S.source_file

            -- New order_id → insert as new row
            WHEN NOT MATCHED THEN INSERT
                (order_id, product_name, quantity, unit_price, order_date,
                 customer_email, region, loaded_at, source_file)
            VALUES
                (S.order_id, S.product_name, S.quantity, S.unit_price, S.order_date,
                 S.customer_email, S.region, S.loaded_at, S.source_file);
        """

        print(f"🔄 Merging rows into final table (upsert on order_id)...")
        query_job = client.query(merge_query)
        query_job.result()

        # Get final row count
        final_table = client.get_table(table_ref)
        print(f"✅ Merge complete. Final table now has {final_table.num_rows} total rows.")

    except Exception as e:
        print(f"❌ Insert into final table failed: {str(e)}")
        raise

    finally:
        # ── 6. Clean up temp table ────────────────────────────────────────
        _cleanup_temp_table(client, temp_table_id)

    print(f"🎉 Pipeline complete for: {gcs_uri}")
    return f"Loaded {load_job.output_rows} rows from {file_name}", 200


def _cleanup_temp_table(client: bigquery.Client, temp_table_id: str):
    """Delete the temporary staging table."""
    try:
        client.delete_table(temp_table_id, not_found_ok=True)
        print(f"🧹 Cleaned up temp table: {temp_table_id}")
    except Exception as e:
        print(f"⚠️  Failed to clean up temp table {temp_table_id}: {str(e)}")
