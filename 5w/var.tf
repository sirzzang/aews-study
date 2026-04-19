########################
# Cluster basics
########################

variable "ClusterBaseName" {
  description = "Base name of the cluster. 5주차 전용으로 기본값을 myeks5w 로 구분한다."
  type        = string
  default     = "myeks5w"
}

variable "KubernetesVersion" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.35"
}

variable "TargetRegion" {
  description = "AWS region where the resources will be created."
  type        = string
  default     = "ap-northeast-2"
}

variable "availability_zones" {
  description = "List of availability zones."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
}

########################
# VPC / subnets
########################

variable "VpcBlock" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "192.168.0.0/16"
}

variable "public_subnet_blocks" {
  description = "List of CIDR blocks for the public subnets."
  type        = list(string)
  default     = ["192.168.0.0/22", "192.168.4.0/22", "192.168.8.0/22"]
}

variable "private_subnet_blocks" {
  description = "List of CIDR blocks for the private subnets."
  type        = list(string)
  default     = ["192.168.12.0/22", "192.168.16.0/22", "192.168.20.0/22"]
}

########################
# System node group (3w와 동일)
########################

variable "WorkerNodeInstanceType" {
  description = "EC2 instance type for the system worker nodes."
  type        = string
  default     = "t3.medium"
}

variable "WorkerNodeCount" {
  description = "Number of system worker nodes."
  type        = number
  default     = 2
}

variable "WorkerNodeVolumesize" {
  description = "Volume size for system worker nodes (in GiB)."
  type        = number
  default     = 30
}

########################
# GPU node group (5주차 추가)
########################

# 비용 가드: NG 최초 생성 시 초기값을 결정한다.
# 이미 존재하는 NG의 스케일링은 lifecycle.ignore_changes로 인해
# TF 경로로 반영되지 않으므로 AWS CLI로 수행한다.
#   aws eks update-nodegroup-config --scaling-config desiredSize=2
#   aws eks update-nodegroup-config --scaling-config desiredSize=0
variable "gpu_desired_size" {
  description = "GPU 노드 그룹 desired_size. 비용 가드를 위해 기본 0."
  type        = number
  default     = 0
}

# max_size=2 인 이유 (2026-04-19 결정):
#   서울 리전 G/VT On-Demand vCPU 쿼터 증설(16 vCPU 요청)이 **8 vCPU 로 부분 승인**되었다.
#   g5.xlarge 는 4 vCPU/대이므로 동시 실행 한도는 **2대**. max_size 를 4 로 두면
#   ASG 롤링(새 노드 선행 기동 → 구 노드 drain) 시점에 일시적으로 3~4대 동시 실행이
#   필요해져 `InsufficientInstanceCapacity`/쿼터 초과로 실패한다.
#   따라서 ASG 레벨에서 아예 2 로 잠가 쿼터 초과 경로를 차단한다.
# 트레이드오프: 2→3 확장이 필요한 롤링 replace·스케일 테스트(C-5 류)는 이 기본값으로는
#   불가. 필요 시 AWS Support 케이스 177652656700539 재오픈하여 16 vCPU 재요청 후
#   `-var gpu_max_size=4` 로 override 하여 apply.
# 배경 상세: results/00-prerequisites/findings.md "부분 승인(8 vCPU) 영향 분석" 섹션 참조.
variable "gpu_max_size" {
  description = "GPU 노드 그룹 max_size. 서울 G/VT 쿼터 8 vCPU(=g5.xlarge 2대) 한도에 맞춰 2 로 고정."
  type        = number
  default     = 2
}

variable "gpu_instance_type" {
  description = "GPU 워커 인스턴스 타입. Option B 기준 g5.xlarge (A10G 24GB)."
  type        = string
  default     = "g5.xlarge"
}

variable "gpu_node_disk_size" {
  description = "GPU 노드 EBS 볼륨 크기(GiB). GPU Operator/CUDA 이미지 고려 100GB 권장."
  type        = number
  default     = 100
}

# C-3(NCCL SG 차단) 시나리오에서 EFA/AZ 간 지연 변수 제거를 위해 같은 AZ에 고정.
# availability_zones[gpu_az_index] 의 private subnet 하나만 사용.
variable "gpu_az_index" {
  description = "GPU 노드를 배치할 AZ 인덱스 (availability_zones 기준). 단일 AZ 고정 목적."
  type        = number
  default     = 0
}

########################
# GPU Operator (helm) — 기본 활성
########################

# default=true 인 이유: 이 프로젝트의 "일상 상태" 는 GPU Operator 가 설치되어 있는 운영 중 구성.
# 매 plan/apply 마다 CLI 로 -var 를 빠뜨리면 state 의 helm_release 가 destroy 대상으로 잡히는 구조를 방지.
# (2026-04-19 C-1 세션 발견. 상세 results/C-1-gpu-operator/findings.md)
#
# 최초 배포 시(E-2/E-3 단계, 아직 operator 설치 전)에는 반드시 다음과 같이 명시:
#   terraform plan  -var enable_gpu_operator=false -out=...
#   terraform apply ...
# GPU Operator 설치 단계(E-4) 부터는 -var 플래그 없이 default(true) 사용.
variable "enable_gpu_operator" {
  description = "NVIDIA GPU Operator helm_release 생성 여부. 기본 true(운영 상태). 최초 클러스터 부트스트랩 시(E-2/E-3)에만 -var enable_gpu_operator=false 로 명시적 override."
  type        = bool
  default     = true
}

variable "gpu_operator_namespace" {
  description = "GPU Operator 설치 네임스페이스."
  type        = string
  default     = "gpu-operator"
}

# 핀 근거 (E-2b-research/findings.md §Part1 참조, 2026-04-19 결정):
#   - K8s 1.35 는 GPU Operator v26.3.x 계열부터 공식 지원 (v25.10.x 이하 미지원)
#   - v26.3.1 이 조회 시점 최신 stable. v26.3.0 대비 SLES/ARM 수정이 주이며 우리 환경(AL2023 x86_64 +
#     driver/toolkit disabled) 에 실질 영향 없음. 최신 패치 흡수 이유로 v26.3.1 채택.
#   - AL2023 NVIDIA AMI 에 NVIDIA driver 580 / container toolkit 이 포함 → Operator 는
#     driver.enabled=false, toolkit.enabled=false 로 두고 devicePlugin/NFD/DCGM/validator 레이어만 사용.
#     이 운영은 AWS 공식 가이드(docs.aws.amazon.com ml-eks-optimized-ami) 권장 경로.
#   - values 스키마 점검: helm show values nvidia/gpu-operator --version v26.3.1 결과
#     driver/toolkit/devicePlugin/nfd/dcgmExporter/validator/operator 최상위 키 + nested enabled/plugin.env/
#     tolerations 구조 모두 현 gpu_operator.tf 오버라이드와 호환.
#   - null(=latest) 유지 시 차후 v27.x 릴리스로 자동 major bump 될 위험 있어 재현성 깨짐. 고정 필수.
# 업데이트 절차: E-4 세션 시작 직전 `helm search repo nvidia/gpu-operator --versions | head`
#   로 v26.3.1 가용성 재확인. yank 되었거나 더 최신 stable 필요 시 이 default 만 갱신 후 apply.
variable "gpu_operator_chart_version" {
  description = "NVIDIA GPU Operator Helm 차트 버전. AL2023 NVIDIA AMI + driver/toolkit disabled 운영 전제에 맞춰 K8s 1.35 호환 최신 stable 로 고정."
  type        = string
  default     = "v26.3.1"
}

########################
# C-3 (NCCL SG 차단) 실험용 토글
########################
# 두 변수 모두 기본 true — 정상 동작.
# C-3 세션에서 `-var enable_aux_sg_vpc_allow=false -var node_sg_enable_recommended_rules=false`
# 로 apply 하면 node 간 NCCL 통신 경로(ephemeral TCP self-ref + VPC 대역 allow)가 함께 차단된다.
# 원복은 둘 다 true 로 돌려 apply 1회.
#
# 주의: node_sg_enable_recommended_rules=false 는 cluster→node webhook(4443/6443/8443/9443/10251)
# 도 함께 꺼진다 (모듈 v21 의 recommended rules 정의 참조). 즉 컨트롤러 webhook 이 깨질 수 있음.
# 실험은 짧게, 원복도 즉시. apply 전 plan diff 로 영향 범위를 반드시 재확인.

variable "enable_aux_sg_vpc_allow" {
  description = "aux node_group_sg 에 VPC 대역 all-traffic ingress 규칙을 둘지 여부. C-3 실험 시 false."
  type        = bool
  default     = true
}

variable "node_sg_enable_recommended_rules" {
  description = "EKS 모듈의 node_security_group_enable_recommended_rules. false 시 ephemeral 1025-65535/tcp self-ref 및 webhook 규칙 다수가 제거됨. C-3 실험 시 false."
  type        = bool
  default     = true
}
