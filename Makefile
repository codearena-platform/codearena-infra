.PHONY: tf-init tf-plan tf-apply k8s-apply k8s-delete

# Terraform Commands
tf-init:
	cd terraform && terraform init

tf-plan:
	cd terraform && terraform plan

tf-apply:
	cd terraform && terraform apply

# Kubernetes Commands
k8s-apply:
	kubectl apply -f k8s/

k8s-delete:
	kubectl delete -f k8s/
