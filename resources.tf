resource "random_uuid" "resource" {}

resource "aws_cloudwatch_event_rule" "resource" {
  name        = coalesce(var.name, random_uuid.resource.id)
  description = var.description

  schedule_expression = var.schedule_expression
  event_pattern       = var.event_pattern
  event_bus_name      = var.event_bus_name

  state    = var.state
  role_arn = var.role_arn

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "resource" {
  for_each = var.targets

  rule           = aws_cloudwatch_event_rule.resource.name
  event_bus_name = var.event_bus_name
  target_id      = each.key
  arn            = each.value.arn
  role_arn       = each.value.role_arn

  input      = each.value.input
  input_path = each.value.input_path

  dynamic "input_transformer" {
    for_each = each.value.input_transformer[*]

    content {
      input_template = input_transformer.value.input_template
      input_paths    = input_transformer.value.input_paths
    }
  }

  dynamic "retry_policy" {
    for_each = each.value.retry_policy[*]

    content {
      maximum_event_age_in_seconds = retry_policy.value.maximum_event_age_in_seconds
      maximum_retry_attempts       = retry_policy.value.maximum_retry_attempts
    }
  }

  dynamic "dead_letter_config" {
    for_each = each.value.dead_letter_arn[*]

    content {
      arn = dead_letter_config.value
    }
  }

  dynamic "ecs_target" {
    for_each = each.value.ecs_target[*]

    content {
      task_definition_arn     = ecs_target.value.task_definition_arn
      task_count              = ecs_target.value.task_count
      launch_type             = ecs_target.value.launch_type
      platform_version        = ecs_target.value.platform_version
      group                   = ecs_target.value.group
      propagate_tags          = ecs_target.value.propagate_tags
      enable_ecs_managed_tags = ecs_target.value.enable_ecs_managed_tags
      enable_execute_command  = ecs_target.value.enable_execute_command
      tags                    = ecs_target.value.tags

      dynamic "network_configuration" {
        for_each = ecs_target.value.network_configuration[*]

        content {
          subnets          = network_configuration.value.subnets
          security_groups  = network_configuration.value.security_groups
          assign_public_ip = network_configuration.value.assign_public_ip
        }
      }

      dynamic "capacity_provider_strategy" {
        for_each = coalesce(ecs_target.value.capacity_provider_strategy, [])

        content {
          capacity_provider = capacity_provider_strategy.value.capacity_provider
          base              = capacity_provider_strategy.value.base
          weight            = capacity_provider_strategy.value.weight
        }
      }

      dynamic "ordered_placement_strategy" {
        for_each = coalesce(ecs_target.value.ordered_placement_strategy, [])

        content {
          type  = ordered_placement_strategy.value.type
          field = ordered_placement_strategy.value.field
        }
      }

      dynamic "placement_constraint" {
        for_each = coalesce(ecs_target.value.placement_constraint, [])

        content {
          type       = placement_constraint.value.type
          expression = placement_constraint.value.expression
        }
      }
    }
  }

  dynamic "run_command_targets" {
    for_each = coalesce(each.value.run_command_targets, [])

    content {
      key    = run_command_targets.value.key
      values = run_command_targets.value.values
    }
  }

  dynamic "http_target" {
    for_each = each.value.http_target[*]

    content {
      header_parameters       = http_target.value.header_parameters
      path_parameter_values   = http_target.value.path_parameter_values
      query_string_parameters = http_target.value.query_string_parameters
    }
  }

  dynamic "sqs_target" {
    for_each = each.value.sqs_target[*]

    content {
      message_group_id = sqs_target.value.message_group_id
    }
  }

  dynamic "batch_target" {
    for_each = each.value.batch_target[*]

    content {
      job_definition = batch_target.value.job_definition
      job_name       = batch_target.value.job_name
      array_size     = batch_target.value.array_size
      job_attempts   = batch_target.value.job_attempts
    }
  }
}

output "id" {
  description = "The ID of the rule, which is its name, prefixed with the event bus name when the rule is on a custom bus."
  value       = aws_cloudwatch_event_rule.resource.id
}

output "arn" {
  description = "The ARN of the rule. A target's resource policy names this ARN as the source that is permitted to invoke it."
  value       = aws_cloudwatch_event_rule.resource.arn
}

output "name" {
  description = "The name of the rule, generated when name was left unset."
  value       = aws_cloudwatch_event_rule.resource.name
}
