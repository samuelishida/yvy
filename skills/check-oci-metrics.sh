#!/bin/bash
# check-oci-metrics.sh
# OCI VM Metrics Checker — Unix/Linux/macOS version
# Usage: bash check-oci-metrics.sh
set -e

C="ocid1.tenancy.oc1..aaaaaaaa5vfmx4xoxmfv577ibav5fk3ablvy56yo4arls7lvyrtbvcsohjha"
REGION="sa-saopaulo-1"
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

echo "=== VMs ==="
oci compute instance list -c $C --region $REGION \
  --query 'data[].{Name:"display-name", State:"lifecycle-state", Shape:shape}' \
  --output table

echo -e "\n=== CPU Summary (last 1h) ==="
oci monitoring metric-data summarize-metrics-data -c $C --region $REGION \
  --namespace oci_computeagent --query-text "CpuUtilization[1m].mean()"

echo -e "\n=== Memory Summary (last 1h) ==="
oci monitoring metric-data summarize-metrics-data -c $C --region $REGION \
  --namespace oci_computeagent --query-text "MemoryUtilization[1m].mean()"

echo -e "\n=== Network Summary (last 1h) ==="
echo "--- Inbound ---"
oci monitoring metric-data summarize-metrics-data -c $C --region $REGION \
  --namespace oci_computeagent --query-text "NetworksBytesIn[1m].mean()"
echo "--- Outbound ---"
oci monitoring metric-data summarize-metrics-data -c $C --region $REGION \
  --namespace oci_computeagent --query-text "NetworksBytesOut[1m].mean()"

echo -e "\n=== Disk Summary (last 1h) ==="
echo "--- Read ---"
oci monitoring metric-data summarize-metrics-data -c $C --region $REGION \
  --namespace oci_computeagent --query-text "DiskBytesRead[1m].mean()"
echo "--- Written ---"
oci monitoring metric-data summarize-metrics-data -c $C --region $REGION \
  --namespace oci_computeagent --query-text "DiskBytesWritten[1m].mean()"

echo -e "\n=== Load Average (last 1h) ==="
oci monitoring metric-data summarize-metrics-data -c $C --region $REGION \
  --namespace oci_computeagent --query-text "LoadAverage[1m].mean()"
