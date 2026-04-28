.PHONY: help build deploy run-local validate status clean

CLUSTER_NAME := mirrord-demo
NAMESPACE    := mirrord-demo

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Compile and test the application (produces target/*.jar)
	mvn -q test package

deploy: ## Create kind cluster (if needed), build image, and deploy all k8s resources
	bash scripts/deploy-demo.sh

run-local: ## Run the app locally with mirrord connected to the in-cluster resources
	bash scripts/run-local-with-mirrord.sh

validate: ## Run the end-to-end validation flow against the kind cluster
	bash scripts/validate-demo.sh

status: ## Show pod status in the demo namespace
	kubectl -n $(NAMESPACE) get pods

clean: ## Delete the kind cluster and all its resources
	kind delete cluster --name $(CLUSTER_NAME)
