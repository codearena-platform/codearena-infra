.PHONY: tf-fmt-check tf-validate tf-init tf-plan tf-apply k8s-apply k8s-delete k8s-validate

NAMESPACE ?= codearena

# Terraform Commands
tf-fmt-check:
	cd terraform && terraform fmt -check -recursive

tf-validate:
	cd terraform && terraform init -backend=false -input=false && terraform validate

tf-init:
	cd terraform && terraform init

tf-plan:
	cd terraform && terraform plan

tf-apply:
	cd terraform && terraform apply

# Kubernetes Commands
k8s-apply:
	kubectl apply -f k8s/ --namespace $(NAMESPACE)

k8s-delete:
	kubectl delete -f k8s/ --namespace $(NAMESPACE)

k8s-validate:
	kubeconform -strict -summary k8s/
