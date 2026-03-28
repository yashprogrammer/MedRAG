# MedRAG Data

Place source files here before running `make index-medrag`.

## Guidelines

Add FDA, WHO, CDC, AHA, or similar guideline PDFs to `guidelines/`.

Suggested starter set:

- diabetes guideline PDFs
- hypertension guideline PDFs
- asthma management guideline PDFs
- DailyMed or FDA label PDFs for common medications

## PubMed

PubMed abstracts are loaded dynamically during indexing from the queries defined in `src/projects/medrag/ingestor.py`.

