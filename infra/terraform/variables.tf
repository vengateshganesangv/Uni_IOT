variable "region" {
  description = "Must match the region hard-coded in emergency_service.js (CloudWatch client)."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  type    = string
  default = "sdr"
}

variable "image_tag" {
  description = "Image tag pushed to ECR by scripts/aws-start.sh"
  type        = string
  default     = "latest"
}

variable "hivemq_username" {
  description = "Credentials for the HiveMQ cluster hard-coded in the services. Required unless use_test_broker = true."
  type        = string
  sensitive   = true
  default     = ""
}

variable "hivemq_password" {
  type      = string
  sensitive = true
  default   = ""
}

# ---- cost / topology switches ----
variable "use_test_broker" {
  description = "TEST ONLY, off by default. Runs a Mosquitto broker inside the VPC and shadows the hard-coded HiveMQ hostname with private DNS, so the unmodified services connect to it instead of HiveMQ. Needs no HiveMQ account."
  type        = bool
  default     = false
}

variable "use_fargate_spot" {
  description = "Run the stateless services (Emergency, Priority) on Fargate Spot (~70% cheaper; tasks can be interrupted, which for QoS0 messaging is equivalent to a scale-in). Rescue and the test broker always use on-demand."
  type        = bool
  default     = true
}

variable "enable_alb" {
  description = "Put an ALB (~US$0.035/h fixed) in front of Emergency. Off by default: Emergency gets a public IP restricted to allowed_cidr (scripts/aws-url.sh prints it). Without an ALB run only 1 Emergency task."
  type        = bool
  default     = false
}

variable "test_broker_cpu" {
  type    = number
  default = 512
}

variable "test_broker_memory" {
  type    = number
  default = 1024
}

variable "allowed_cidr" {
  description = "CIDR allowed to call POST /emergency through the ALB. The endpoint is unauthenticated and amplifies 1 request into up to 100,000 MQTT messages, so never leave this open (aws-start.sh passes your public IP as /32)."
  type        = string
}

# ---- sizing ----
variable "emergency_desired_count" {
  description = "Keep at 1 unless enable_alb = true (without an ALB clients can only reach one task)."
  type        = number
  default     = 1
}

variable "emergency_cpu" {
  type    = number
  default = 512
}

variable "emergency_memory" {
  type    = number
  default = 1024
}

variable "priority_cpu" {
  type    = number
  default = 256
}

variable "priority_memory" {
  type    = number
  default = 512
}

variable "rescue_cpu" {
  type    = number
  default = 256
}

variable "rescue_memory" {
  type    = number
  default = 512
}

# ---- Priority Service autoscaling ----
variable "priority_min_capacity" {
  description = "Warm floor. Reactive scale-out is likely slower than a seconds-long burst, so raise this to pre-provision capacity for a max event."
  type        = number
  default     = 1
}

variable "priority_max_capacity" {
  description = "Cost cap as well as a connection cap: each task is one broker connection (HiveMQ Cloud free plan allows 100 in total)."
  type        = number
  default     = 4
}

variable "scale_steps" {
  description = "Step scaling on Sum(IncomingRequests) per 10s. lower = request threshold (ascending; the first is the alarm threshold), add = tasks to add. Tiers mirror getRequestCount()."
  type = list(object({
    lower = number
    add   = number
  }))
  default = [
    { lower = 5000, add = 1 },
    { lower = 20000, add = 2 },
    { lower = 60000, add = 4 },
    { lower = 150000, add = 6 },
  ]
}

variable "scale_out_cooldown" {
  type    = number
  default = 60
}

variable "scale_in_idle_minutes" {
  description = "Minutes with no IncomingRequests before scale-in starts (one task removed per cooldown)."
  type        = number
  default     = 10
}

variable "scale_in_cooldown" {
  type    = number
  default = 300
}

variable "log_retention_days" {
  type    = number
  default = 3
}
