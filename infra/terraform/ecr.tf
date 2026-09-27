locals {
  # "broker" exists only for the optional test broker
  services = concat(["emergency", "priority", "rescue"], var.use_test_broker ? ["broker"] : [])
}

resource "aws_ecr_repository" "svc" {
  for_each             = toset(local.services)
  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # the terminate script must be able to remove repos that still hold images

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Cost: keep only the 3 newest images per repo (every deploy pushes a new tag).
resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 3 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 3 }
      action       = { type = "expire" }
    }]
  })
}
