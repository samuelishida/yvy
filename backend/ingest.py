import os
from dotenv import load_dotenv
load_dotenv()

import backend

def main():
    backend.logger.info("Starting ingestion process.", extra={"event": "ingest_start"})
    backend.download_and_extract_data()
    color_legend = backend.parse_qml("/app/prodes_brasil_2023.qml")
    coordinates = backend.parse_tif("/app/prodes_brasil_2023.tif")

    existing_count = backend.mongo.db.deforestation_data.count_documents({})
    if existing_count == 0:
        backend.insert_data_to_mongo_parallel(color_legend, coordinates)
        backend.logger.info("Ingestion completed.", extra={"event": "ingest_complete"})
    else:
        backend.logger.info(
            "MongoDB already contains documents. No ingestion necessary.",
            extra={"event": "ingest_skipped", "details": {"documents": existing_count}},
        )

if __name__ == "__main__":
    main()
