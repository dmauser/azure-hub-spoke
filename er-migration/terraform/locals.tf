locals {
  common_tags = merge(
    {
      managedBy = "terraform"
    },
    var.tags
  )
}
