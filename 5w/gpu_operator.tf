########################
# NVIDIA GPU Operator (Helm) — 기본 비활성
########################
#
# 이 파일은 E-2 세션(Terraform 코드 초안) 단계에서는 var.enable_gpu_operator = false 로 두고
# plan 단계까지만 검증한다. 실제 Helm 설치는 쿼터 승인 후 GPU 노드가 올라온 다음 세션(E-4)에서 진행.
#
# 참고:
#  - AL2023_x86_64_NVIDIA AMI 는 NVIDIA 드라이버/NVIDIA container toolkit 이 이미 포함되어 있다.
#    따라서 GPU Operator 를 설치할 때는 driver.enabled=false, toolkit.enabled=false 로 주는 것이 기본.
#  - devicePlugin 은 AMI 에 포함되지 않으므로 true (기본) 로 둔다.
#  - 값은 values 파일로 분리하지 않고 inline 로 둔다 — 시나리오 C-2(Device Plugin 끄고/켜기)에서
#    ClusterPolicy CR 을 kubectl 로 직접 건드릴 예정이라 Terraform 재apply 주기가 필요 없음.

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.TargetRegion
      ]
    }
  }
}

resource "helm_release" "gpu_operator" {
  count = var.enable_gpu_operator ? 1 : 0

  name             = "gpu-operator"
  namespace        = var.gpu_operator_namespace
  create_namespace = true
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = var.gpu_operator_chart_version
  timeout          = 900
  atomic           = false # 실습 중 실패 원인 관찰을 위해 일부러 rollback 비활성
  wait             = true

  # AL2023 NVIDIA AMI 가 드라이버/toolkit 을 가지고 있으므로 해당 컴포넌트는 GPU Operator에서 비활성.
  # Device Plugin, NFD, DCGM, Validator 등 나머지 레이어만 GPU Operator가 담당.
  values = [yamlencode({
    driver = {
      enabled = false
    }
    toolkit = {
      enabled = false
    }
    devicePlugin = {
      enabled = true
    }
    nfd = {
      enabled = true
    }
    dcgmExporter = {
      enabled = true
    }
    validator = {
      plugin = {
        env = [
          {
            name  = "WITH_WORKLOAD"
            value = "true"
          }
        ]
      }
    }
    # GPU taint 가 걸려 있으므로 operator 구성요소도 toleration 필요
    operator = {
      tolerations = [
        {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]
    }
  })]

  depends_on = [module.eks]
}
