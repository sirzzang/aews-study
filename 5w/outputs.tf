output "configure_kubectl" {
  description = "kubeconfig 업데이트 명령어"
  value       = "aws eks --region ${var.TargetRegion} update-kubeconfig --name ${var.ClusterBaseName}"
}

output "cluster_name" {
  description = "EKS 클러스터 이름"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "EKS 모듈이 생성한 클러스터 SG. C-3 에서 건드리지 말 것 (컨트롤플레인↔노드 통신)."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "EKS 모듈이 생성한 노드 SG. C-3 (NCCL SG 차단) 실습 시 self-ref 규칙을 제거할 대상."
  value       = module.eks.node_security_group_id
}

output "auxiliary_node_sg_id" {
  description = "본 Terraform 에서 보조로 붙인 node_group_sg (VPC 대역 all traffic 허용)"
  value       = aws_security_group.node_group_sg.id
}

output "gpu_subnet_az" {
  description = "GPU 노드가 배치된 단일 AZ"
  value       = local.gpu_subnet_az
}

output "gpu_subnet_id" {
  description = "GPU 노드 그룹이 사용하는 private subnet id (단일 AZ)"
  value       = local.gpu_subnet_ids[0]
}

output "ami_al2023_standard" {
  description = "시스템 노드 AMI (AL2023 standard)"
  # SSM parameter value 는 기본 sensitive — AMI id 는 민감하지 않으므로 nonsensitive 로 래핑
  value = nonsensitive(data.aws_ssm_parameter.eks_ami_al2023_std.value)
}

output "ami_al2023_nvidia" {
  description = "GPU 노드 AMI (AL2023 nvidia) — 참고용"
  value       = nonsensitive(data.aws_ssm_parameter.eks_ami_al2023_nvidia.value)
}
