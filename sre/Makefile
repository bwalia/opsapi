# OpsAPI SRE — demo & operations entrypoint.
# `make help` lists everything. The Docker demo is fully self-contained.
COMPOSE := docker compose -f docker-compose.sre.yml --env-file .env.sre
ENV_FILE := .env.sre

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

$(ENV_FILE):
	@cp .env.sre.example $(ENV_FILE) && echo "Created $(ENV_FILE) from example"

.PHONY: demo-up
demo-up: $(ENV_FILE) ## Bring up the full SRE stack and print the URL map
	@./scripts/sre-demo.sh

.PHONY: demo-down
demo-down: ## Stop the SRE stack (keep volumes)
	@$(COMPOSE) --profile load down

.PHONY: demo-clean
demo-clean: ## Stop the stack and delete all data volumes
	@$(COMPOSE) --profile load down -v

.PHONY: demo-load
demo-load: ## Run the k6 load generator (drives golden signals + budget burn)
	@$(COMPOSE) --profile load run --rm k6

.PHONY: status
status: ## Show container status
	@$(COMPOSE) ps

.PHONY: logs
logs: ## Tail logs (usage: make logs SVC=prometheus)
	@$(COMPOSE) logs -f $(SVC)

.PHONY: alerts
alerts: ## Show alerts received by the local webhook sink (pages/tickets)
	@docker logs sre-alert-logger 2>&1 | tail -50

.PHONY: validate
validate: ## Validate compose + promtool rules + amtool config
	@./scripts/validate.sh

.PHONY: backup-test
backup-test: ## Prove RPO: pg_dump the demo DB, restore into a throwaway DB, verify
	@./scripts/backup-test.sh

.PHONY: dr-drill
dr-drill: ## Measure RTO: kill a dependency, time recovery, write a report
	@./scripts/dr-drill.sh

.PHONY: chaos
chaos: ## Chaos test: pause Postgres, assert PostgresDown fires, then recover
	@./scripts/chaos-test.sh
