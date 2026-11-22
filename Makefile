.PHONY: tf-fmt-check tf-validate tf-init tf-plan tf-apply k8s-render k8s-apply k8s-delete k8s-validate test

NAMESPACE ?= codearena
K8S_DIR ?= k8s
RENDERED_DIR ?= .rendered/k8s
IMAGES_ENV ?= $(K8S_DIR)/images.env

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
k8s-render:
	python3 scripts/render_k8s.py $(K8S_DIR) $(RENDERED_DIR) --images-env $(IMAGES_ENV)

k8s-apply: k8s-render
	kubectl apply -f $(RENDERED_DIR)/ --namespace $(NAMESPACE)

k8s-delete: k8s-render
	kubectl delete -f $(RENDERED_DIR)/ --namespace $(NAMESPACE)

k8s-validate: k8s-render
	kubeconform -strict -summary $(RENDERED_DIR)/

test:
	python3 -m unittest discover -s tests -v
