########################
# Provider Definitions #
########################

# AWS 공급자: 지정된 리전에서 AWS 리소스를 설정
provider "aws" {
  region = var.TargetRegion
}

########################
# EKS-optimized AMI (system / NVIDIA)
########################

# 시스템 노드 — AL2023 x86_64 standard
data "aws_ssm_parameter" "eks_ami_al2023_std" {
  name = "/aws/service/eks/optimized-ami/${var.KubernetesVersion}/amazon-linux-2023/x86_64/standard/recommended/image_id"
}

# GPU 노드 — AL2023 x86_64 NVIDIA 최적화 AMI.
# 참고: AMI id 자체는 EKS 모듈이 ami_type 로 분기하므로 실제 활용 경로보다는
# 로그/검증용으로 data source 로 별도 보존. (findings.md 에서 AMI 버전 diff 비교)
data "aws_ssm_parameter" "eks_ami_al2023_nvidia" {
  name = "/aws/service/eks/optimized-ami/${var.KubernetesVersion}/amazon-linux-2023/x86_64/nvidia/recommended/image_id"
}

########################
# Security Group Setup
########################

# 보안 그룹: EKS 워커 노드용 보조 보안 그룹.
# 주의:
#   - 이 SG 는 3w 관례대로 "추가" 부여되는 SG 다. (vpc_security_group_ids 에 함께 바인딩)
#   - EKS 모듈이 자동 생성하는 node SG 에 이미 self-reference(ingress_self_all) 규칙이 포함되므로
#     인터 노드 파드-파드 통신(예: NCCL)은 기본 허용.
#   - C-3(NCCL SG 차단) 시나리오에서 건드릴 대상은 "모듈이 만든 node SG" 쪽이며, 여기 이 SG 가 아니다.
resource "aws_security_group" "node_group_sg" {
  name        = "${var.ClusterBaseName}-node-group-sg"
  description = "Auxiliary security group for EKS Node Group (shared by system & GPU NG)"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${var.ClusterBaseName}-node-group-sg"
  }
}

# 보조 SG inbound: VPC 대역 내에서 노드로 all traffic 허용 (3w 패턴 유지, 실습 편의용).
# C-3(NCCL SG 차단) 실험 시 이 규칙을 제거해야 pod-pod 통신이 실제로 차단된다.
# → var.enable_aux_sg_vpc_allow=false 로 count=0 하여 규칙 자체를 내린다.
resource "aws_security_group_rule" "allow_vpc_all" {
  count = var.enable_aux_sg_vpc_allow ? 1 : 0

  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [var.VpcBlock]
  security_group_id = aws_security_group.node_group_sg.id
}

# aux SG egress: 노드가 외부(EKS API, ECR, NGC, Route53 등) 로 나갈 수 있도록 allow-all.
# 항상 유지 — 이 규칙은 node_sg_enable_recommended_rules=false 로 내렸을 때 모듈 node SG 의
# egress_all 이 함께 빠지는 부작용의 안전망. SG 는 여러 개 중 하나라도 egress 를 허용하면 통과.
resource "aws_security_group_rule" "aux_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_group_sg.id
  description       = "Node egress to anywhere (safety net for C-3 experiment)"
}

################
# IAM Policies
################

# AWS Load Balancer Controller가 ELB를 관리할 수 있도록 허용하는 IAM 정책
resource "aws_iam_policy" "aws_lb_controller_policy" {
  name        = "${var.ClusterBaseName}AWSLoadBalancerControllerPolicy"
  description = "Policy for allowing AWS LoadBalancerController to modify AWS ELB"
  policy      = file("aws_lb_controller_policy.json")
}

# ExternalDNS가 Route 53 DNS 레코드를 관리할 수 있도록 허용하는 IAM 정책
resource "aws_iam_policy" "external_dns_policy" {
  name        = "${var.ClusterBaseName}ExternalDNSPolicy"
  description = "Policy for allowing ExternalDNS to modify Route 53 records"
  policy      = file("externaldns_controller_policy.json")
}

# CAS가 AWS AutoScaling 관리할 수 있도록 허용하는 IAM 정책
resource "aws_iam_policy" "aws_cas_autoscaler_policy" {
  name        = "${var.ClusterBaseName}CasAutoScalerPolicy"
  description = "Policy for allowing CAS to management AWS AutoScaling"
  policy      = file("cas_autoscaling_policy.json")
}

########################
# 입력 검증 (apply 전 plan 단계에서 gate)
########################
# gpu_max_size < gpu_desired_size 로 apply 하면 EKS managed node group 이 만들다 실패한다.
# 15~20분 날리지 않도록 plan 단계에서 선차단.
resource "terraform_data" "validate_inputs" {
  lifecycle {
    precondition {
      condition     = var.gpu_max_size >= var.gpu_desired_size
      error_message = "gpu_max_size (${var.gpu_max_size}) must be >= gpu_desired_size (${var.gpu_desired_size})."
    }
    precondition {
      condition     = var.gpu_az_index >= 0 && var.gpu_az_index < length(var.availability_zones)
      error_message = "gpu_az_index (${var.gpu_az_index}) is out of range for availability_zones list (length ${length(var.availability_zones)})."
    }
  }
}

########################
# Locals — GPU 단일 AZ 서브넷 추출
########################

# VPC 모듈이 azs 순서대로 private_subnets 를 반환하므로, gpu_az_index 로 하나만 선택한다.
# 선택 이유: C-3 시나리오에서 "같은 AZ" 전제를 강제해 EFA/크로스-AZ 지연 변수를 제거.
locals {
  gpu_subnet_ids = [module.vpc.private_subnets[var.gpu_az_index]]
  gpu_subnet_az  = var.availability_zones[var.gpu_az_index]
}

########################
# EKS
########################

# https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.ClusterBaseName
  kubernetes_version = var.KubernetesVersion

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  endpoint_public_access  = true
  endpoint_private_access = true

  # controlplane log
  enabled_log_types = [
    "api",
    "scheduler"
  ]

  enable_cluster_creator_admin_permissions = true

  # Node SG 규칙은 모듈 기본값을 따르되 recommended_rules 플래그는 변수로 감싼다.
  # 중요 finding: v21 기본값은 "all ports self-ref" 가 아니며, recommended_rules 가
  # 포함하는 ephemeral 1025-65535/tcp self-ref 가 NCCL 통신의 실질 경로다.
  # → var.node_sg_enable_recommended_rules=false 로 내리면 해당 self-ref 가 빠져 C-3 재현 가능.
  # 다만 같은 recommended 세트에 cluster→node webhook(4443/6443/8443/9443/10251) 도 포함되므로
  # 실험은 짧게 / 원복 즉시. 영향 범위는 apply 전 plan diff 로 확인.
  create_node_security_group                   = true
  node_security_group_enable_recommended_rules = var.node_sg_enable_recommended_rules

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    # 1st — 시스템 노드 그룹 (3w 동일)
    primary = {
      name                   = "${var.ClusterBaseName}-ng-1"
      use_name_prefix        = false
      ami_type               = "AL2023_x86_64_STANDARD"
      instance_types         = [var.WorkerNodeInstanceType]
      desired_size           = var.WorkerNodeCount
      max_size               = var.WorkerNodeCount + 2
      min_size               = var.WorkerNodeCount - 1
      disk_size              = var.WorkerNodeVolumesize
      # terraform-aws-modules/eks v21 managed NG 는 submodule 변수명이 subnet_ids (list(string)).
      # 상위 모듈은 coalesce(each.value.subnet_ids, var.subnet_ids) 로 전달하므로
      # 다른 키(예: subnets)는 조용히 무시되고 상위 var.subnet_ids 로 fallback 된다.
      subnet_ids             = module.vpc.private_subnets
      vpc_security_group_ids = [aws_security_group.node_group_sg.id]

      iam_role_name            = "${var.ClusterBaseName}-ng-1"
      iam_role_use_name_prefix = false
      iam_role_additional_policies = {
        "${var.ClusterBaseName}AWSLoadBalancerControllerPolicy" = aws_iam_policy.aws_lb_controller_policy.arn
        "${var.ClusterBaseName}ExternalDNSPolicy"               = aws_iam_policy.external_dns_policy.arn
        "${var.ClusterBaseName}CasAutoScalerPolicy"             = aws_iam_policy.aws_cas_autoscaler_policy.arn
        AmazonSSMManagedInstanceCore                            = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      labels = {
        tier = "primary"
      }

      cloudinit_pre_nodeadm = [
        {
          content_type = "application/node.eks.aws"
          content      = <<-EOT
            ---
            apiVersion: node.eks.aws/v1alpha1
            kind: NodeConfig
            spec:
              kubelet:
                config:
                  maxPods: 50
          EOT
        },
        {
          content_type = "text/x-shellscript"
          content      = <<-EOT
            #!/bin/bash
            echo "Starting custom initialization..."
            dnf update -y
            dnf install -y tree bind-utils tcpdump nvme-cli links sysstat ipset htop
            echo "Custom initialization completed."
          EOT
        }
      ]
    }

    # 2nd — GPU 노드 그룹 (5주차 추가)
    #   - ami_type AL2023_x86_64_NVIDIA : EKS 최적화 GPU AMI(드라이버 포함)
    #   - 같은 AZ (gpu_subnet_ids) 에 고정하여 NCCL/EFA 변수 최소화
    #   - taint: 시스템 파드가 GPU 노드에 뜨지 않도록 차단
    #   - label: GPU Operator 및 사용자 워크로드 nodeSelector 용
    #   - desired_size: var.gpu_desired_size (기본 0) — 비용 가드
    gpu = {
      name                   = "${var.ClusterBaseName}-ng-gpu"
      use_name_prefix        = false
      ami_type               = "AL2023_x86_64_NVIDIA"
      capacity_type          = "ON_DEMAND"
      instance_types         = [var.gpu_instance_type]
      desired_size           = var.gpu_desired_size
      max_size               = var.gpu_max_size
      min_size               = 0
      disk_size              = var.gpu_node_disk_size
      # 단일 AZ 고정을 실제로 적용하는 키. submodule 변수명이 subnet_ids 이므로 이 이름이 맞다.
      # 이전 `subnets = local.gpu_subnet_ids` 는 E-3 apply 에서 조용히 무시되어
      # GPU NG 가 3개 private subnet(multi-AZ) 로 붙었었다. 속성명 교정 후 단일 AZ 복원.
      # 주의: `aws_eks_node_group.subnet_ids` 는 ForceNew → gpu NG destroy+create.
      #       desired=0 이라 EC2 기동/종료 없음. 약 7~10분 소요 예상.
      subnet_ids             = local.gpu_subnet_ids
      vpc_security_group_ids = [aws_security_group.node_group_sg.id]

      iam_role_name            = "${var.ClusterBaseName}-ng-gpu"
      iam_role_use_name_prefix = false
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      labels = {
        tier             = "gpu"
        "nvidia.com/gpu" = "true"
      }

      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      # GPU AMI 는 이미 NVIDIA 드라이버/toolkit 포함. 추가 도구만 설치.
      cloudinit_pre_nodeadm = [
        {
          content_type = "text/x-shellscript"
          content      = <<-EOT
            #!/bin/bash
            echo "Starting GPU node custom initialization..."
            dnf install -y tree bind-utils tcpdump nvme-cli links sysstat ipset htop pciutils
            echo "GPU node custom initialization completed."
          EOT
        }
      ]

      tags = {
        "k8s.io/cluster-autoscaler/node-template/label/nvidia.com/gpu" = "true"
        "k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu" = "true:NoSchedule"
      }
    }
  }

  # add-on
  addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    metrics-server = {
      most_recent = true
    }
    external-dns = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    cert-manager = {
      most_recent = true
    }
  }

  tags = {
    Environment = "cloudneta-lab"
    Terraform   = "true"
    Week        = "aews-5w"
  }
}
