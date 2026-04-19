terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    # helm v2 계열로 고정. v3.x 는 kubernetes = {...} 속성 문법을 쓰지만
    # v2.x 는 nested block(kubernetes { ... }) 을 쓴다. gpu_operator.tf 와 문법을 맞추기 위해 v2 고정.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    # 아래는 EKS/VPC 모듈이 전이적으로 요구하는 provider 들. init 로그상 자동 설치되지만
    # 협업/재현성을 위해 root 에서 명시적으로 기록. 버전은 init 로그에 찍힌 값을 기준으로 >= 로.
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = ">= 2.0.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
  }
}
