mock_provider "aws" {
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/mock-rule"
    }
  }
}

run "invalid_name_characters_are_rejected" {
  command = plan

  variables {
    name                = "nightly/report"
    schedule_expression = "rate(1 day)"
  }

  expect_failures = [var.name]
}

run "overlong_name_is_rejected" {
  command = plan

  variables {
    name                = "a-rule-name-that-runs-well-past-the-sixty-four-character-ceiling-aws-enforces"
    schedule_expression = "rate(1 day)"
  }

  expect_failures = [var.name]
}

run "a_rule_with_neither_trigger_is_rejected" {
  command = plan

  variables {
    name = "orphan"
  }

  expect_failures = [var.schedule_expression]
}

run "a_rule_with_both_triggers_is_rejected" {
  command = plan

  variables {
    name                = "ambiguous"
    schedule_expression = "rate(1 day)"
    event_pattern       = "{\"source\":[\"aws.ec2\"]}"
  }

  expect_failures = [var.schedule_expression]
}

run "a_scheduled_rule_on_a_custom_bus_is_rejected" {
  command = plan

  variables {
    name                = "nightly-report"
    schedule_expression = "cron(0 3 * * ? *)"
    event_bus_name      = "orders"
  }

  expect_failures = [var.schedule_expression]
}

run "a_five_field_cron_expression_is_rejected" {
  command = plan

  variables {
    name                = "nightly-report"
    schedule_expression = "cron(0 3 * * *)"
  }

  expect_failures = [var.schedule_expression]
}

run "a_rate_expression_with_a_mismatched_unit_is_rejected" {
  command = plan

  variables {
    name                = "hourly-report"
    schedule_expression = "rate(1 hours)"
  }

  expect_failures = [var.schedule_expression]
}

run "an_invalid_state_is_rejected" {
  command = plan

  variables {
    name                = "nightly-report"
    schedule_expression = "rate(1 day)"
    state               = "PAUSED"
  }

  expect_failures = [var.state]
}

run "an_invalid_target_key_is_rejected" {
  command = plan

  variables {
    name                = "nightly-report"
    schedule_expression = "rate(1 day)"

    targets = {
      "report builder" = {
        arn = "arn:aws:lambda:us-east-1:123456789012:function:report-builder"
      }
    }
  }

  expect_failures = [var.targets]
}

run "input_and_input_transformer_together_are_rejected" {
  command = plan

  variables {
    name                = "nightly-report"
    schedule_expression = "rate(1 day)"

    targets = {
      report_builder = {
        arn               = "arn:aws:lambda:us-east-1:123456789012:function:report-builder"
        input             = "{\"mode\":\"full\"}"
        input_transformer = { input_template = "{\"mode\":\"full\"}" }
      }
    }
  }

  expect_failures = [var.targets]
}

run "an_ecs_target_without_a_role_is_rejected" {
  command = plan

  variables {
    name                = "nightly-report"
    schedule_expression = "rate(1 day)"

    targets = {
      batch_job = {
        arn = "arn:aws:ecs:us-east-1:123456789012:cluster/reporting"

        ecs_target = {
          task_definition_arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/report:1"
        }
      }
    }
  }

  expect_failures = [var.targets]
}

run "name_defaults_to_random_uuid" {
  command = apply

  variables {
    schedule_expression = "rate(1 day)"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.resource.name == random_uuid.resource.id
    error_message = "Leaving name unset should fall back to the generated random_uuid."
  }
}

run "a_generated_name_fits_the_aws_name_limit" {
  command = apply

  variables {
    schedule_expression = "rate(1 day)"
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.resource.name) <= 64
    error_message = "A generated rule name must fit AWS's 64-character ceiling without truncation."
  }
}

run "a_rate_expression_is_accepted" {
  command = plan

  variables {
    name                = "every-five-minutes"
    schedule_expression = "rate(5 minutes)"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.resource.schedule_expression == "rate(5 minutes)"
    error_message = "A rate expression should reach the rule unaltered."
  }

  assert {
    condition     = aws_cloudwatch_event_rule.resource.event_pattern == null
    error_message = "A scheduled rule should carry no event pattern."
  }
}

run "a_scheduled_rule_on_the_named_default_bus_is_accepted" {
  command = plan

  variables {
    name                = "nightly-report"
    schedule_expression = "cron(0 3 * * ? *)"
    event_bus_name      = "default"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.resource.event_bus_name == "default"
    error_message = "Naming the default bus explicitly should be accepted, since a scheduled rule does fire there."
  }
}

run "an_event_pattern_rule_on_a_custom_bus_is_accepted" {
  command = plan

  variables {
    name           = "order-placed"
    event_bus_name = "orders"
    event_pattern  = "{\"source\":[\"com.example.orders\"]}"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.resource.schedule_expression == null
    error_message = "An event-pattern rule should carry no schedule expression."
  }
}

run "no_targets_by_default" {
  command = plan

  variables {
    name                = "nightly-report"
    schedule_expression = "rate(1 day)"
  }

  assert {
    condition     = length(aws_cloudwatch_event_target.resource) == 0
    error_message = "Leaving targets unset should create no target resources."
  }
}

run "targets_create_one_resource_each_keyed_by_target_id" {
  command = apply

  variables {
    name                = "nightly-report"
    schedule_expression = "rate(1 day)"

    targets = {
      report_builder = {
        arn = "arn:aws:lambda:us-east-1:123456789012:function:report-builder"
      }
      audit_queue = {
        arn = "arn:aws:sqs:us-east-1:123456789012:report-audit"
      }
      notify = {
        arn   = "arn:aws:sns:us-east-1:123456789012:reports"
        input = "{\"mode\":\"full\"}"
      }
    }
  }

  assert {
    condition     = length(aws_cloudwatch_event_target.resource) == 3
    error_message = "Each targets entry should create one target resource."
  }

  assert {
    condition     = aws_cloudwatch_event_target.resource["notify"].target_id == "notify"
    error_message = "A target should take its target_id from the caller-written map key, so adding one does not renumber the others."
  }

  assert {
    condition     = aws_cloudwatch_event_target.resource["report_builder"].rule == aws_cloudwatch_event_rule.resource.name
    error_message = "Every target should attach to the rule this module creates."
  }
}

run "a_target_carries_its_own_retry_and_dead_letter_settings" {
  command = apply

  variables {
    name          = "instance-terminated"
    event_pattern = "{\"source\":[\"aws.ec2\"]}"

    targets = {
      audit_queue = {
        arn             = "arn:aws:sqs:us-east-1:123456789012:instance-audit"
        dead_letter_arn = "arn:aws:sqs:us-east-1:123456789012:failed-invocations"

        retry_policy = {
          maximum_retry_attempts       = 4
          maximum_event_age_in_seconds = 3600
        }
      }
      notify = {
        arn = "arn:aws:sns:us-east-1:123456789012:instance-events"
      }
    }
  }

  assert {
    condition     = length(aws_cloudwatch_event_target.resource["audit_queue"].dead_letter_config) == 1
    error_message = "Supplying dead_letter_arn should produce a dead_letter_config block on that target alone."
  }

  assert {
    condition     = length(aws_cloudwatch_event_target.resource["notify"].dead_letter_config) == 0
    error_message = "A target without dead_letter_arn should carry no dead_letter_config block, since the setting is per target."
  }

  assert {
    condition     = one(aws_cloudwatch_event_target.resource["audit_queue"].retry_policy).maximum_retry_attempts == 4
    error_message = "A target's retry_policy should reach the resource as supplied."
  }
}

run "a_target_may_omit_every_optional_block" {
  command = apply

  variables {
    name                = "nightly-report"
    schedule_expression = "rate(1 day)"

    targets = {
      report_builder = {
        arn = "arn:aws:lambda:us-east-1:123456789012:function:report-builder"
      }
    }
  }

  assert {
    condition     = length(aws_cloudwatch_event_target.resource["report_builder"].ecs_target) == 0
    error_message = "A Lambda target should produce no ecs_target block."
  }

  assert {
    condition     = length(aws_cloudwatch_event_target.resource["report_builder"].input_transformer) == 0
    error_message = "A target that supplies no input_transformer should produce no such block."
  }

  assert {
    condition     = aws_cloudwatch_event_target.resource["report_builder"].role_arn == null
    error_message = "A Lambda target needs no role, since Lambda authorizes EventBridge through a resource policy instead."
  }
}

run "an_ecs_target_expands_its_nested_blocks" {
  command = apply

  variables {
    name          = "deploy-requested"
    event_pattern = "{\"source\":[\"com.example.deploys\"]}"

    targets = {
      migration_task = {
        arn      = "arn:aws:ecs:us-east-1:123456789012:cluster/reporting"
        role_arn = "arn:aws:iam::123456789012:role/eventbridge-ecs"

        ecs_target = {
          task_definition_arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/migrate:1"
          launch_type         = "FARGATE"
          task_count          = 1

          network_configuration = {
            subnets          = ["subnet-aaaaaaaa", "subnet-bbbbbbbb"]
            security_groups  = ["sg-aaaaaaaa"]
            assign_public_ip = false
          }

          placement_constraint = [
            { type = "memberOf", expression = "attribute:ecs.availability-zone in [us-east-1a]" },
          ]
        }
      }
    }
  }

  assert {
    condition     = length(one(aws_cloudwatch_event_target.resource["migration_task"].ecs_target).network_configuration) == 1
    error_message = "An ecs_target supplying network_configuration should expand exactly one such block."
  }

  assert {
    condition     = length(one(aws_cloudwatch_event_target.resource["migration_task"].ecs_target).placement_constraint) == 1
    error_message = "Each placement_constraint entry should expand into one block."
  }

  assert {
    condition     = length(one(aws_cloudwatch_event_target.resource["migration_task"].ecs_target).capacity_provider_strategy) == 0
    error_message = "An omitted capacity_provider_strategy list should expand into no blocks rather than failing on a null."
  }
}

run "an_input_transformer_reshapes_the_event" {
  command = apply

  variables {
    name          = "instance-terminated"
    event_pattern = "{\"source\":[\"aws.ec2\"]}"

    targets = {
      notify = {
        arn = "arn:aws:sns:us-east-1:123456789012:instance-events"

        input_transformer = {
          input_paths    = { instance = "$.detail.instance-id" }
          input_template = "\"Instance <instance> has terminated.\""
        }
      }
    }
  }

  assert {
    condition     = one(aws_cloudwatch_event_target.resource["notify"].input_transformer).input_template == "\"Instance <instance> has terminated.\""
    error_message = "An input_transformer's template should reach the resource unaltered."
  }
}

run "targets_inherit_the_rules_event_bus" {
  command = apply

  variables {
    name           = "order-placed"
    event_bus_name = "orders"
    event_pattern  = "{\"source\":[\"com.example.orders\"]}"

    targets = {
      fulfilment = {
        arn = "arn:aws:lambda:us-east-1:123456789012:function:fulfilment"
      }
    }
  }

  assert {
    condition     = aws_cloudwatch_event_target.resource["fulfilment"].event_bus_name == "orders"
    error_message = "A target on a custom bus must name the same bus as its rule, which the module should derive rather than ask for twice."
  }
}

run "readme_scheduled_example" {
  command = plan

  variables {
    name                = "nightly-report"
    description         = "Runs the nightly reporting job"
    schedule_expression = "cron(0 3 * * ? *)"

    targets = {
      report_builder = {
        arn = "arn:aws:lambda:us-east-1:123456789012:function:report-builder"
      }
    }
  }
}

run "readme_event_pattern_example" {
  command = plan

  variables {
    name        = "ec2-instance-terminated"
    description = "Responds to an EC2 instance entering the terminated state"

    event_pattern = jsonencode({
      source      = ["aws.ec2"]
      detail-type = ["EC2 Instance State-change Notification"]
      detail      = { state = ["terminated"] }
    })

    targets = {
      audit_queue = {
        arn             = "arn:aws:sqs:us-east-1:123456789012:instance-audit"
        dead_letter_arn = "arn:aws:sqs:us-east-1:123456789012:eventbridge-failed-invocations"

        retry_policy = {
          maximum_retry_attempts       = 4
          maximum_event_age_in_seconds = 3600
        }
      }
    }
  }
}
