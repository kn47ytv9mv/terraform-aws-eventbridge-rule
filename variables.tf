variable "name" {
  default     = null
  description = "Name of the rule, unique within its event bus. Up to 64 characters of letters, digits, periods, hyphens, and underscores. If null, a unique name is generated."

  validation {
    condition     = var.name == null || can(regex("^[-._A-Za-z0-9]+$", var.name))
    error_message = "A rule name may contain only letters, digits, periods, hyphens, and underscores."
  }

  validation {
    condition     = var.name == null || length(var.name) <= 64
    error_message = "A rule name may be at most 64 characters long."
  }
}

variable "schedule_expression" {
  default     = null
  description = "Schedule on which the rule fires, as 'rate(5 minutes)' or 'cron(0 3 * * ? *)'. AWS's cron syntax takes six fields rather than the five a Unix crontab uses, and a rate expression's unit is singular only for a value of 1. Exactly one of schedule_expression or event_pattern is required, and a scheduled rule only fires on the default event bus."

  validation {
    condition     = (var.schedule_expression == null) != (var.event_pattern == null)
    error_message = "Exactly one of schedule_expression or event_pattern is required. A rule with neither matches nothing and never fires. A rule with both self-triggers on the schedule and additionally fires on every matching event, which is almost never intended; write two rules when both behaviours are genuinely wanted."
  }

  validation {
    condition     = var.schedule_expression == null || var.event_bus_name == null || var.event_bus_name == "default"
    error_message = "schedule_expression is supported only on the default event bus. AWS accepts a scheduled rule on a custom bus and then never fires it, so set event_bus_name to null or 'default', or use event_pattern instead."
  }

  validation {
    condition = var.schedule_expression == null || anytrue([
      can(regex("^cron\\(([^ ]+ ){5}[^ ]+\\)$", var.schedule_expression)),
      can(regex("^rate\\((1 (minute|hour|day)|([2-9]|[1-9][0-9]+) (minutes|hours|days))\\)$", var.schedule_expression)),
    ])
    error_message = "schedule_expression must be a cron expression of exactly six whitespace-separated fields, as in 'cron(0 3 * * ? *)' — minutes, hours, day-of-month, month, day-of-week, and a year field a five-field Unix crontab does not have — or a rate expression of a positive value and a unit of minutes, hours, or days whose plurality matches that value, as in 'rate(1 hour)' or 'rate(5 hours)'."
  }
}

variable "event_pattern" {
  default     = null
  description = "JSON pattern matched against events arriving on the bus, most conveniently written with jsonencode. Exactly one of schedule_expression or event_pattern is required."
}

variable "event_bus_name" {
  default     = null
  description = "Event bus the rule and its targets live on. If null, the account's default bus receives events from AWS services. A custom bus cannot carry a scheduled rule, and this module does not create the bus itself."
}

variable "targets" {
  default     = {}
  description = "Destinations invoked when the rule matches, keyed by a name you write literally. The key becomes the target's target_id, so it may contain only letters, digits, periods, hyphens, and underscores, up to 64 characters. Keying by a name rather than by arn matters: a target ARN is routinely another module's output, which Terraform does not know while building the plan, and a for_each key derived from an unknown value fails the plan outright. Each target's input, input_path, and input_transformer are mutually exclusive, and retry_policy and dead_letter_arn are configured per target rather than once for the rule."
  type = map(object({
    arn        = string
    role_arn   = optional(string)
    input      = optional(string)
    input_path = optional(string)

    input_transformer = optional(object({
      input_template = string
      input_paths    = optional(map(string))
    }))

    retry_policy = optional(object({
      maximum_event_age_in_seconds = optional(number)
      maximum_retry_attempts       = optional(number)
    }))

    dead_letter_arn = optional(string)

    ecs_target = optional(object({
      task_definition_arn     = string
      task_count              = optional(number)
      launch_type             = optional(string)
      platform_version        = optional(string)
      group                   = optional(string)
      propagate_tags          = optional(string)
      enable_ecs_managed_tags = optional(bool)
      enable_execute_command  = optional(bool)
      tags                    = optional(map(string))

      network_configuration = optional(object({
        subnets          = set(string)
        security_groups  = optional(set(string))
        assign_public_ip = optional(bool)
      }))

      capacity_provider_strategy = optional(list(object({
        capacity_provider = string
        base              = optional(number)
        weight            = optional(number)
      })))

      ordered_placement_strategy = optional(list(object({
        type  = string
        field = optional(string)
      })))

      placement_constraint = optional(list(object({
        type       = string
        expression = optional(string)
      })))
    }))

    run_command_targets = optional(list(object({
      key    = string
      values = list(string)
    })))

    http_target = optional(object({
      header_parameters       = optional(map(string))
      path_parameter_values   = optional(list(string))
      query_string_parameters = optional(map(string))
    }))

    sqs_target = optional(object({
      message_group_id = string
    }))

    batch_target = optional(object({
      job_definition = string
      job_name       = string
      array_size     = optional(number)
      job_attempts   = optional(number)
    }))
  }))

  validation {
    condition = alltrue([
      for key in keys(var.targets) :
      can(regex("^[-._A-Za-z0-9]+$", key)) && length(key) <= 64
    ])
    error_message = "A targets key becomes the target_id, so it may contain only letters, digits, periods, hyphens, and underscores, up to 64 characters."
  }

  validation {
    condition = alltrue([
      for target in var.targets :
      length([for supplied in [target.input, target.input_path, target.input_transformer] : supplied if supplied != null]) <= 1
    ])
    error_message = "A target's input, input_path, and input_transformer are mutually exclusive: supply at most one of them."
  }

  validation {
    condition = alltrue([
      for target in var.targets :
      target.ecs_target == null || target.role_arn != null
    ])
    error_message = "An ecs_target requires role_arn, the role EventBridge assumes to run the task. ECS exposes no resource policy for EventBridge to be granted through instead."
  }
}

variable "description" {
  default     = null
  description = "Human-readable explanation of what the rule matches and why, up to 512 characters. Worth setting: a rule named for its target reveals nothing about the event that triggers it."
}

variable "state" {
  default     = null
  description = "Whether the rule is active: 'ENABLED', 'DISABLED', or 'ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS'. If null, AWS enables the rule. The last value is required only to match CloudTrail management events that AWS does not deliver to the default bus otherwise. This replaces the deprecated is_enabled argument, which this module does not expose."

  validation {
    condition     = var.state == null || contains(["ENABLED", "DISABLED", "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"], var.state)
    error_message = "state must be 'ENABLED', 'DISABLED', or 'ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS'."
  }
}

variable "role_arn" {
  default     = null
  description = "IAM role EventBridge assumes for the rule itself, which applies only when the rule forwards events to an event bus in another account or Region. A role needed to invoke a particular target belongs on that target instead."
}

variable "tags" {
  default     = null
  description = "A map of tags to assign to the rule. Targets carry no tags of their own."
}
