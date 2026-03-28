UV ?= uv

.PHONY: install qdrant-up qdrant-down compose-up compose-down index-medrag run-medrag run-ui test eval-medrag

install:
	$(UV) sync --extra dev

qdrant-up:
	docker compose up -d

qdrant-down:
	docker compose down

compose-up:
	docker compose up --build

compose-down:
	docker compose down

index-medrag:
	$(UV) run python -m src.cli index --project medrag

run-medrag:
	ACTIVE_PROJECT=medrag $(UV) run uvicorn src.api.main:app --reload

run-ui:
	$(UV) run streamlit run src/ui/app.py

test:
	$(UV) run pytest tests

eval-medrag:
	$(UV) run pytest eval/medrag/test_medrag.py -s
