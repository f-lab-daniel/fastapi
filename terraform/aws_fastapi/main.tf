############################################################
#
# 요청 흐름:
#   브라우저 → ALB(80) → 워커 노드의 NodePort(30080) → Service → FastAPI Pod(80)
#                                                       └→ RDS PostgreSQL(5432)
#
# 만들어지는 것:
#   1. VPC        : 퍼블릭/프라이빗 서브넷 2개씩(AZ 2개), IGW, NAT Gateway 1개
#   2. ECR        : FastAPI 도커 이미지 저장소
#   3. EKS        : 컨트롤 플레인 + 관리형 노드 그룹(t3.medium x 2)
#   4. ALB        : 인터넷에서 들어오는 HTTP를 노드로 전달
#   5. RDS        : PostgreSQL 1대 (프라이빗 서브넷)
#   6. K8s 리소스 : Deployment, NodePort Service, DB 접속 정보 Secret
#
# AWS 연결 원리:
#   Terraform과 AWS를 따로 "연결"하는 작업은 없다. provider "aws"는 AWS CLI와 같은 순서로
#   자격 증명을 찾는다: 환경변수(AWS_ACCESS_KEY_ID, AWS_PROFILE 등) → ~/.aws 프로필(SSO 포함)
#   → EC2/CI에 붙은 IAM 역할. 즉 터미널에서 aws 명령이 내 계정으로 동작하면 terraform도 같은 계정을 쓴다.
#   리전은 아래 var.region(서울)으로 고정되어 있어 CLI 설정의 리전과는 무관하다.
#
# AWS 연결 절차:
#   1) 실습용 자격 증명 준비
#      AWS 콘솔에서 실습용 IAM 사용자(또는 IAM Identity Center 사용자)를 만든다.
#      이 예제는 EKS와 노드용 IAM 역할을 직접 만들기 때문에 PowerUser 권한으로는 부족하다.
#      실습 계정이라면 AdministratorAccess가 가장 간단하다.
#
#   2) 프로필 등록 (둘 중 하나)
#      # 액세스 키 방식
#      aws configure --profile flab
#      #   Access Key / Secret Key 입력, region: ap-northeast-2, output: json
#
#      # SSO 방식 (회사/조직 계정이면 이쪽이 권장)
#      aws configure sso --profile flab
#      aws sso login --profile flab
#
#   3) 제대로 붙었는지 확인
#      aws sts get-caller-identity --profile flab
#      # Account가 실습용 계정 번호로 나오면 성공
#
#   4) 이 프로필로 Terraform 실행
#      export AWS_PROFILE=flab      # 이 터미널에서는 모든 aws/terraform 명령이 flab 계정으로 감
#      cd ~/Desktop/devel/flab/fastapi/terraform/aws_fastapi
#      terraform init
#      terraform plan               # 만들어질 리소스 확인 (37개)
#      terraform apply
#
#   5) apply 후 kubectl과 docker 연결
#      둘 다 같은 AWS_PROFILE을 쓴다. Terraform 출력값을 그대로 실행하면 된다.
#      $(terraform output -raw kubeconfig_command)   # kubectl이 EKS를 바라보게 설정
#      kubectl get nodes                              # 노드 2개 Ready 확인
#      terraform output -raw ecr_push_commands        # 출력된 3줄을 fastapi 루트에서 실행
#
#   주의: 같은 PC에 운영(production) 계정 프로필이 있다면, AWS_PROFILE을 잘못 둔 채로 apply하면
#         운영 계정에 리소스가 생긴다. 아래 provider "aws"의 안전장치 주석 참고.
#
# 사용 순서:
#   1) terraform init && terraform apply                     (15~20분, EKS 생성이 오래 걸림)
#   2) 출력된 ecr_push_commands 대로 이미지 빌드·푸시
#      - 맥(M1/M2)에서 빌드할 때는 --platform linux/amd64 필수 (노드가 x86 t3.medium)
#   3) kubectl rollout restart -n fastapi deployment/fastapi  (이미지가 늦게 올라갔다면)
#   4) 출력된 app_url 을 브라우저로 열기 (ALB 헬스체크 통과까지 1~2분)
#   5) 실습이 끝나면 반드시 terraform destroy
#
# 비용 주의 (서울 리전, 대략):
#   EKS 컨트롤 플레인 시간당 $0.10, NAT Gateway 시간당 약 $0.06 + 트래픽,
#   t3.medium x 2, ALB, db.t4g.micro → 켜두면 하루 약 $10 안팎. 실습 후 destroy.
#
# 보안 주의:
#   RDS 비밀번호는 random_password로 만들어 terraform.tfstate에 평문으로 남는다.
#   tfstate는 git에 올리지 말 것. 실무에서는 S3 + DynamoDB(또는 S3 lockfile) 원격 상태를 쓴다.
############################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

############################################################
# 변수
############################################################

variable "region" {
  description = "배포할 AWS 리전"
  type        = string
  default     = "ap-northeast-2" # 서울
}

variable "name" {
  description = "모든 리소스 이름 앞에 붙는 접두사"
  type        = string
  default     = "flab-fastapi"
}

variable "image_tag" {
  description = "ECR에 푸시한 FastAPI 이미지 태그"
  type        = string
  default     = "v1"
}

############################################################
# Provider
############################################################

# AWS provider: 모든 리소스에 공통 태그를 붙여 콘솔에서 찾기 쉽게 한다.
#
# 안전장치 (선택):
#   운영 계정 프로필이 같은 PC에 있다면 아래 두 줄을 넣는 것을 권한다.
#   allowed_account_ids에 없는 계정으로 실행하면 plan 단계에서 바로 에러가 나서 엉뚱한 계정에 배포되지 않는다.
#   (넣을 경우 variable "aws_profile"(기본값 "flab")과 variable "allowed_account_id"도 함께 선언)
#
#   provider "aws" {
#     region              = var.region
#     profile             = var.aws_profile          # 기본값 "flab"
#     allowed_account_ids = [var.allowed_account_id] # 실습 계정이 아니면 plan 단계에서 바로 에러
#     ...
#   }
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.name
      ManagedBy = "terraform"
    }
  }
}

# Kubernetes provider: 아래에서 만든 EKS 클러스터에 바로 접속해 Deployment 등을 만든다.
# kubeconfig 파일 없이 클러스터 주소, CA 인증서, 임시 토큰으로 접속한다.
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}

# 리전에서 사용 가능한 가용 영역(AZ) 목록. 앞의 2개만 쓴다.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # 서브넷 CIDR: VPC 10.0.0.0/16 안을 /24로 나눈다.
  public_subnet_cidrs  = ["10.0.0.0/24", "10.0.1.0/24"]   # ALB, NAT Gateway
  private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"] # EKS 노드, RDS

  node_port = 30080 # ALB가 노드로 보낼 포트 (K8s NodePort 범위 30000~32767)
}

############################################################
# 1. 네트워크 (VPC)
#
# [전체 그림]
#
#   인터넷
#     │
#   ┌─┴──────────── VPC 10.0.0.0/16 ─────────────────────────────┐
#   │ IGW (인터넷 게이트웨이)                                      │
#   │  │                                                          │
#   │  ├── AZ-a ───────────────────┐  ├── AZ-b ─────────────────┐ │
#   │  │ 퍼블릭 10.0.0.0/24         │  │ 퍼블릭 10.0.1.0/24       │ │
#   │  │   ALB, NAT Gateway         │  │   ALB                   │ │
#   │  │ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │  │ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ │ │
#   │  │ 프라이빗 10.0.10.0/24       │  │ 프라이빗 10.0.11.0/24    │ │
#   │  │   EKS 노드, RDS            │  │   EKS 노드, (RDS 대기)    │ │
#   │  └────────────────────────────┘  └─────────────────────────┘ │
#   └──────────────────────────────────────────────────────────────┘
#
# [VPC (Virtual Private Cloud)]
#   AWS 안에 나만 쓰는 격리된 사설 네트워크. 회사 사무실 네트워크를 클라우드에 하나 깐다고 보면 된다.
#   CIDR 10.0.0.0/16 은 "10.0.x.x 대역 65,536개 IP를 이 VPC가 쓴다"는 뜻이고,
#   이걸 다시 /24(256개씩)로 잘라 서브넷을 만든다.
#
# [AZ (Availability Zone, 가용 영역)]
#   한 리전(서울) 안에 물리적으로 떨어진 데이터센터 묶음. 정전·화재가 나도 다른 AZ는 살아 있다.
#   AZ를 2개 쓰는 이유:
#     - 한 AZ가 통째로 죽어도 서비스가 유지되게 (고가용성)
#     - ALB는 서로 다른 AZ의 서브넷이 최소 2개 있어야 만들 수 있다
#     - RDS 서브넷 그룹도 최소 2개 AZ를 요구한다 (Multi-AZ 전환 대비)
#
# [서브넷: 퍼블릭 vs 프라이빗]
#   서브넷은 VPC를 잘게 나눈 구역이고, 하나의 서브넷은 하나의 AZ에만 속한다.
#   퍼블릭/프라이빗은 서브넷의 "종류"가 따로 있는 게 아니라 **라우팅 테이블이 어디를 가리키느냐**로 갈린다.
#     - 퍼블릭 서브넷 : 기본 경로(0.0.0.0/0)가 IGW → 인터넷과 직접 주고받을 수 있다.
#                      외부에서 들어와야 하는 것(ALB)과 NAT Gateway를 둔다.
#     - 프라이빗 서브넷: 기본 경로가 NAT Gateway → 밖으로 나갈 수는 있지만 밖에서 들어올 수는 없다.
#                      직접 노출되면 안 되는 것(애플리케이션 서버, DB)을 둔다.
#   이렇게 나누면 외부 요청은 반드시 ALB를 거쳐야 하고, 노드와 DB는 인터넷에서 직접 공격받지 않는다.
#
# [왜 AZ마다 퍼블릭 1개 + 프라이빗 1개씩인가]
#   서브넷은 AZ 하나에만 속할 수 있어서, "여러 AZ에 걸친 서브넷"은 만들 수 없다.
#   그래서 AZ마다 필요한 역할의 서브넷을 하나씩 따로 만들어 짝을 맞춘다.
#     - 퍼블릭이 AZ마다 있어야 하는 이유:
#         ALB는 AZ마다 자기 노드(진입점)를 서브넷 안에 만든다. AZ-b에 퍼블릭 서브넷이 없으면
#         AZ-a가 죽었을 때 인터넷에서 들어올 입구가 사라진다. (애초에 ALB는 2개 AZ 미만이면 생성 불가)
#     - 프라이빗이 AZ마다 있어야 하는 이유:
#         EKS 노드를 두 AZ에 나눠 띄워야 한쪽 AZ가 죽어도 남은 노드에서 Pod가 계속 돈다.
#         RDS도 장애 시 다른 AZ로 넘어갈 수 있도록(Multi-AZ) 두 AZ의 서브넷을 미리 지정해 둔다.
#   즉 "AZ 하나 = 입구(퍼블릭) + 일하는 곳(프라이빗)이 다 갖춰진 독립된 한 세트"가 되도록 만든 것이고,
#   어느 한 세트가 통째로 사라져도 나머지 세트만으로 서비스가 돌아가게 하려는 구조다.
#
#   더 나누지 않은 이유:
#     - 실무에서는 프라이빗을 다시 "앱용"과 "DB용"으로 나눠 3계층(public / app / db)으로 많이 쓴다.
#       DB 서브넷은 NAT 경로조차 없애 인터넷으로 나가는 길을 완전히 막을 수 있기 때문이다.
#     - 이 예제는 최소 구성이 목적이라 보안 그룹(RDS는 EKS 노드에서 오는 5432만 허용)으로 대신 막고
#       2계층으로 단순하게 둔다.
#
# [IGW (Internet Gateway)]
#   VPC와 인터넷을 잇는 출입문. 양방향(들어오고 나가기) 통신이 된다.
#   단, 퍼블릭 IP가 붙은 리소스만 IGW를 통해 인터넷과 통신할 수 있다.
#
# [NAT Gateway (Network Address Translation)]
#   프라이빗 서브넷의 리소스가 "밖으로만" 나갈 수 있게 해 주는 대리인.
#   프라이빗 노드의 요청을 NAT가 자기 공인 IP(EIP)로 바꿔서 대신 보내고, 응답만 다시 돌려준다.
#   밖에서 먼저 연결을 시작할 수는 없다 (단방향).
#   이 예제에서 EKS 노드는 NAT를 통해 ECR 이미지 pull, EKS API 통신, OS 패키지 다운로드를 한다.
#   NAT Gateway 자체는 퍼블릭 서브넷에 있어야 한다 (자기도 IGW를 통해 나가야 하므로).
#
#   NAT를 1개만 둔 이유와 트레이드오프:
#     - NAT Gateway는 개당 시간 요금 + 처리 트래픽 요금이 붙는다. 실습 비용을 줄이려고 1개만 둔다.
#     - 대신 NAT가 있는 AZ-a가 죽으면 AZ-b의 노드도 밖으로 못 나간다 (단일 장애점, SPOF).
#     - AZ-b 노드의 트래픽이 AZ-a의 NAT를 거치면서 AZ 간 전송 요금도 생긴다.
#     - 실무에서는 AZ마다 NAT를 1개씩 두고, 각 AZ의 프라이빗 라우팅 테이블이 자기 AZ의 NAT를 보게 한다.
#       (ECR·S3 트래픽이 많다면 VPC Endpoint로 NAT를 거치지 않게 해서 비용을 줄이기도 한다.)
############################################################

# VPC: 이 예제의 모든 리소스가 들어가는 격리된 사설 네트워크.
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true # EKS 노드와 RDS 엔드포인트의 DNS 이름 해석에 필요

  tags = { Name = "${var.name}-vpc" }
}

# 인터넷 게이트웨이: 퍼블릭 서브넷이 인터넷과 직접 통신하는 출입구.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

# 퍼블릭 서브넷 (AZ마다 1개): 인터넷에서 접근 가능한 영역. ALB와 NAT Gateway가 위치한다.
# ALB는 최소 2개 AZ의 서브넷이 필요해서 2개를 만든다.
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.name}-public-${local.azs[count.index]}" }
}

# 프라이빗 서브넷 (AZ마다 1개): 인터넷에서 직접 들어올 수 없는 영역. EKS 노드와 RDS를 둔다.
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${var.name}-private-${local.azs[count.index]}" }
}

# NAT Gateway: 프라이빗 서브넷의 노드가 밖으로 나가는 통로 (ECR 이미지 pull, EKS API 통신 등).
# 밖에서 안으로는 못 들어온다. 비용을 줄이려고 1개만 둔다 (실무에서는 AZ마다 1개로 이중화).
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.name}-nat" }

  depends_on = [aws_internet_gateway.this]
}

# 라우팅 테이블: 퍼블릭은 IGW로, 프라이빗은 NAT로 나가도록 기본 경로(0.0.0.0/0)를 정한다.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${var.name}-private-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

############################################################
# 2. 컨테이너 이미지 저장소 (ECR)
############################################################

# ECR: 도커 이미지를 올려두는 AWS 레지스트리. EKS 노드가 여기서 이미지를 pull 한다.
resource "aws_ecr_repository" "app" {
  name                 = "${var.name}-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # destroy 때 이미지가 남아 있어도 저장소를 지운다 (실습용)

  image_scanning_configuration {
    scan_on_push = true # 푸시할 때 이미지 취약점 스캔
  }
}

############################################################
# 3. Kubernetes 클러스터 (EKS)
############################################################

# EKS 클러스터 IAM 역할: AWS가 컨트롤 플레인을 운영하면서 내 계정 리소스(ENI 등)를 다룰 권한.
resource "aws_iam_role" "cluster" {
  name = "${var.name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# EKS 클러스터 (컨트롤 플레인): API 서버, etcd, 스케줄러를 AWS가 관리해 준다.
# version을 생략하면 생성 시점의 EKS 기본(최신) 버전으로 만들어진다.
# 오래된 버전은 표준 지원이 끝나면 연장 지원 요금이 붙으니 버전을 고정할 때는 지원 기간을 확인할 것.
resource "aws_eks_cluster" "this" {
  name     = "${var.name}-eks"
  role_arn = aws_iam_role.cluster.arn

  # 접근 권한을 EKS Access Entry(API)로 관리한다.
  # terraform을 실행한 사용자에게 클러스터 관리자 권한을 자동으로 준다 → 바로 kubectl 가능.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_public_access  = true # 내 PC에서 kubectl / terraform으로 접속하기 위해 공개
    endpoint_private_access = true # 노드는 VPC 내부 경로로 API 서버에 접속
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# 노드 IAM 역할: 워커 노드(EC2)가 클러스터에 합류하고, Pod 네트워크를 만들고, ECR에서 이미지를 받을 권한.
resource "aws_iam_role" "node" {
  name = "${var.name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",          # 클러스터 합류
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",               # Pod에 VPC IP 할당 (VPC CNI)
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly", # ECR 이미지 pull
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# 관리형 노드 그룹: Pod가 실제로 실행되는 EC2 워커 노드 묶음. 프라이빗 서브넷에 둔다.
# 내부적으로 Auto Scaling Group이 만들어지고, 아래 ALB 대상 그룹을 이 ASG에 연결한다.
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id

  instance_types = ["t3.medium"] # x86. 맥에서 빌드한 이미지는 linux/amd64로 빌드해야 한다.

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

############################################################
# 4. 로드밸런서 (ALB)
############################################################

# ALB 보안 그룹: 인터넷에서 80 포트만 허용.
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "Allow HTTP from internet to ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 노드 보안 그룹 규칙: ALB에서 오는 NodePort(30080) 트래픽만 노드로 들어오게 연다.
# 관리형 노드 그룹은 EKS가 만든 클러스터 보안 그룹을 노드에 붙이므로 거기에 규칙을 추가한다.
resource "aws_vpc_security_group_ingress_rule" "node_from_alb" {
  security_group_id            = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = local.node_port
  to_port                      = local.node_port
  ip_protocol                  = "tcp"
  description                  = "ALB to FastAPI NodePort"
}

# ALB 본체: 퍼블릭 서브넷 2곳에 걸쳐 만들어지는 인터넷용 L7 로드밸런서.
resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

# 대상 그룹: ALB가 요청을 보낼 대상(워커 노드의 30080 포트)과 헬스체크 방법.
# 헬스체크가 통과한 노드로만 트래픽이 간다. 노드는 받은 요청을 Service를 통해 Pod로 전달한다.
resource "aws_lb_target_group" "app" {
  name        = "${var.name}-tg"
  port        = local.node_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.this.id

  health_check {
    path                = "/" # FastAPI 루트 경로 (Hello World)
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# 리스너: ALB의 80 포트로 들어온 요청을 위 대상 그룹으로 전달.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# 노드 그룹의 Auto Scaling Group을 대상 그룹에 연결:
# 노드가 늘거나 교체돼도 새 노드가 자동으로 ALB 대상에 등록된다.
resource "aws_autoscaling_attachment" "nodes" {
  autoscaling_group_name = aws_eks_node_group.this.resources[0].autoscaling_groups[0].name
  lb_target_group_arn    = aws_lb_target_group.app.arn
}

############################################################
# 5. 데이터베이스 (RDS PostgreSQL)
############################################################

# RDS 보안 그룹: EKS 노드(클러스터 보안 그룹)에서 오는 5432 포트만 허용. 인터넷 접근 불가.
resource "aws_security_group" "rds" {
  name        = "${var.name}-rds-sg"
  description = "Allow PostgreSQL from EKS nodes"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "PostgreSQL from EKS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# DB 서브넷 그룹: RDS를 어느 서브넷에 둘지 지정. 프라이빗 서브넷 2개(AZ 2개)가 필요하다.
resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-subnet"
  subnet_ids = aws_subnet.private[*].id
}

# DB 마스터 비밀번호. RDS 비밀번호에 쓸 수 없는 문자(/, @, ", 공백)는 빼고 만든다.
resource "random_password" "db" {
  length           = 20
  special          = true
  override_special = "!#$%^&*()-_=+"
}

# RDS 인스턴스: 실습용 최소 사양 PostgreSQL. engine_version을 생략하면 기본 버전으로 만든다.
resource "aws_db_instance" "this" {
  identifier     = "${var.name}-db"
  engine         = "postgres"
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "app"
  username = "app_user"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false # 퍼블릭 IP 없음. VPC 안(EKS Pod)에서만 접속
  multi_az               = false # 실습용 단일 AZ (실무에서는 true로 장애 대비)

  skip_final_snapshot = true # destroy 때 최종 스냅샷 생략 (실습용)
  deletion_protection = false
}

############################################################
# 6. Kubernetes 리소스 (FastAPI 배포)
############################################################

# 네임스페이스: 이 앱의 K8s 리소스를 묶는 공간.
resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = "fastapi"
  }

  depends_on = [aws_eks_node_group.this]
}

# DB 접속 정보 Secret: Pod에 환경변수 DATABASE_URL로 주입된다.
resource "kubernetes_secret_v1" "db" {
  metadata {
    name      = "fastapi-db"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  data = {
    DATABASE_URL = "postgresql://${aws_db_instance.this.username}:${urlencode(random_password.db.result)}@${aws_db_instance.this.address}:5432/${aws_db_instance.this.db_name}"
  }
}

# Deployment: ECR 이미지로 FastAPI Pod 2개를 띄우고, 죽으면 다시 살린다.
resource "kubernetes_deployment_v1" "app" {
  metadata {
    name      = "fastapi"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { app = "fastapi" }
  }

  # 첫 apply 시점에는 아직 이미지를 푸시하기 전이라 Pod가 뜨지 못한다.
  # 롤아웃 완료를 기다리지 않게 해서 apply가 멈추지 않도록 한다.
  wait_for_rollout = false

  spec {
    replicas = 2

    selector {
      match_labels = { app = "fastapi" }
    }

    template {
      metadata {
        labels = { app = "fastapi" }
      }

      spec {
        container {
          name  = "fastapi"
          image = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"

          port {
            container_port = 80 # tiangolo/uvicorn-gunicorn-fastapi 이미지의 기본 포트
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.db.metadata[0].name
            }
          }

          resources {
            requests = { cpu = "250m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          # Readiness Probe: 준비된 Pod에만 트래픽을 보낸다.
          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          # Liveness Probe: 응답이 없는 Pod는 재시작한다.
          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }
        }
      }
    }
  }
}

# Service(NodePort): 모든 노드의 30080 포트로 들어온 요청을 FastAPI Pod들로 분산한다.
# ALB → 노드:30080 → 이 Service → Pod:80 순서로 요청이 전달된다.
resource "kubernetes_service_v1" "app" {
  metadata {
    name      = "fastapi"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  spec {
    type     = "NodePort"
    selector = { app = "fastapi" }

    port {
      port        = 80
      target_port = 80
      node_port   = local.node_port
    }
  }
}

############################################################
# 출력값
############################################################

output "app_url" {
  description = "브라우저로 열어볼 주소 (ALB DNS)"
  value       = "http://${aws_lb.this.dns_name}"
}

output "ecr_repository_url" {
  description = "이미지를 푸시할 ECR 주소"
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_push_commands" {
  description = "fastapi 프로젝트 루트(Dockerfile 위치)에서 실행할 이미지 빌드·푸시 명령"
  value       = <<-EOT
    aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${split("/", aws_ecr_repository.app.repository_url)[0]}
    docker build --platform linux/amd64 -t ${aws_ecr_repository.app.repository_url}:${var.image_tag} .
    docker push ${aws_ecr_repository.app.repository_url}:${var.image_tag}
  EOT
}

output "kubeconfig_command" {
  description = "로컬 kubectl을 이 클러스터에 연결하는 명령"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.name}"
}

output "rds_endpoint" {
  description = "RDS 접속 주소 (VPC 내부에서만 접근 가능)"
  value       = aws_db_instance.this.address
}
