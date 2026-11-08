#!/usr/bin/env bash
# Gallery backfill-gap diagnostics. Safe to run read-only (step 6 mutates).
# Substitue NET if your compose project name is not "seraph".
NET=seraph_internal
NATS_SRV=nats://nats:4222
FILE_PROVIDER=storage
GALLERY_PROVIDER=storage          # change if gallerySourceFolders.physicalProviderId differs
PREFIX='^/Benni/Photos/Pixel 6'

echo "=== 0. compose network name (sanity) ==="
docker network ls | grep _internal

echo
echo "=== 1. gallery source folder state (PRIME SUSPECT: backfillDone) ==="
docker exec mongodb mongosh seraph-gallery --quiet --eval \
  'JSON.stringify(db.gallerySourceFolders.find({},{name:1,spaceProviderId:1,path:1,physicalProviderId:1,physicalPath:1,backfillDone:1,backfillCursor:1,rescanRunning:1,deleted:1}).toArray())'

echo
echo "=== 2. origin of the 215 gallery photos: backfill placeholders vs live-healed ==="
docker exec mongodb mongosh seraph-gallery --quiet --eval \
  "JSON.stringify(db.galleryPhotos.aggregate([{\$match:{providerId:\"$GALLERY_PROVIDER\",path:{\$regex:\"$PREFIX\"}}},{\$group:{_id:\"\$metadataPending\",n:{\$sum:1}}}]).toArray())"

echo
echo "=== 3. file-index: pending vs processed for the prefix ==="
docker exec mongodb mongosh seraph-files --quiet --eval \
  "JSON.stringify(db.files.aggregate([{\$match:{providerId:\"$FILE_PROVIDER\",path:{\$regex:\"$PREFIX\"}}},{\$group:{_id:\"\$pending\",n:{\$sum:1}}}]).toArray())"

echo
echo "=== 4a. SERAPH_FILE_CHANGED stream info (retention: Max Age/Msgs/Bytes) ==="
docker run --rm --network "$NET" natsio/nats-box \
  nats stream info SERAPH_FILE_CHANGED -s "$NATS_SRV"

echo
echo "=== 4b. last 50 FileChangedEvents (grep for your providerId) ==="
docker run --rm --network "$NET" natsio/nats-box \
  nats stream get SERAPH_FILE_CHANGED --last 50 -s "$NATS_SRV" 2>&1 | grep -i "$FILE_PROVIDER" | tail -20

echo
echo "=== 4c. gallery ingest consumer info (lag / outstanding acks) ==="
docker run --rm --network "$NET" natsio/nats-box \
  nats consumer info SERAPH_FILE_CHANGED SERAPH_GALLERY_INGEST -s "$NATS_SRV"

echo
echo "=== 4d. file-indexer consumer info (did FileInfoEvents even flow?) ==="
docker run --rm --network "$NET" natsio/nats-box \
  nats consumer info SERAPH_FILE_INFO SERAPH_FILE_INDEXER -s "$NATS_SRV"

echo
echo "=== 5. gallery logs: backfill / ingest / prefix / resolve / failures ==="
docker logs --since 24h seraph-gallery-1 2>&1 | grep -iE 'backfill|ingest|prefix|declined|failed to process|does not resolve' | tail -50

echo
echo "=== 6. FIX (writes!): reset backfill + restart gallery so resumeIncompleteBackfills re-runs ==="
echo "Comment out the next two lines to actually run the fix:"
# docker exec mongodb mongosh seraph-gallery --quiet --eval \
#   'db.gallerySourceFolders.updateMany({backfillDone:true},{$set:{backfillDone:false,backfillCursor:""}})'
# docker compose restart gallery
