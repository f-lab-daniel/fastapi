terraform {

  required_providers {

    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }

  }
}

provider "helm" {

  kubernetes = {
    config_path    = "~/.kube/config"
    config_context = "kind-flab"
  }
}

resource "helm_release" "terraform-fastapi" {

  name = "terraform-fastapi"

  chart = "../../fastapi"

  values = [
    file("../../fastapi/values.yaml")
  ]
}
