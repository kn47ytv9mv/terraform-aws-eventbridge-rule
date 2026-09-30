# terraform-aws-eventbridge-rule

Terraform module for an EventBridge rule and the targets it invokes —
the one resource that both runs something on a schedule and responds to
something that happened in AWS.

## Cost

EventBridge does not charge for events that AWS services publish to your
account's default bus, nor for matching them against a rule or
delivering them to a target. Events you publish yourself, events a rule
forwards to another account or Region, and invocations sent to an API
destination are each billed per million events. Event replay and schema
discovery are billed separately again, and the target's own invocation
bills under that service rather than here: a Lambda function billed for
its duration, an ECS task for the capacity it runs on. A scheduled rule
that fires every minute therefore costs nothing itself while still
billing for every invocation it causes. See AWS's
[EventBridge pricing](https://aws.amazon.com/eventbridge/pricing/) page
for current rates.

## Design

Targets are bundled into this module rather than split into a separate
one, and both halves of the test for that hold. They are homogeneous: an
ARN plus optional delivery settings, whatever service sits behind the
ARN. Nothing outside the module needs to reference one specifically,
because `aws_cloudwatch_event_target` exposes no identifier of its own
beyond the `target_id` the caller already wrote. And a rule with no
targets matches events and then discards them, so the two are never
useful apart. Same bundling reasoning as
[`terraform-aws-sns-topic`](https://github.com/kn47ytv9mv/terraform-aws-sns-topic)
and its subscriptions.

`targets` is a map keyed by a name you write literally, and the key
becomes that target's `target_id`. Keying by the target ARN instead
would be the obvious alternative and is a trap: the ARN is normally
another module's output, Terraform does not know an output's value while
it is building the plan, and a `for_each` key derived from an unknown
value fails the plan outright with *"the for_each map includes keys
derived from resource attributes that cannot be determined until
apply."* A caller-written key is always known, and it also means adding
a target never renumbers and recreates the others.

### Scheduling fires only on the default event bus

**A rule with a `schedule_expression` runs only on the default event
bus.** Terraform and the EventBridge API both accept a scheduled rule on
a custom bus, report it as created, and then never fire it — a failure
whose only symptom is that nothing happens. AWS states the restriction
plainly in
[Creating a scheduled rule](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-create-rule-schedule.html):
"You can only create scheduled rules using the default event bus."

This module therefore rejects the combination at plan time: setting
`schedule_expression` requires `event_bus_name` to be null or
`"default"`. It is the single most valuable thing the module does,
because it converts silence into an error message.

Exactly one of `schedule_expression` or `event_pattern` is required, and
that too is validated. AWS requires at least one — a rule with neither
matches nothing — and accepts both, in which case the rule self-triggers
on the schedule *and* fires on every matching event. That is almost
never what somebody meant to write, so this module requires one; declare
two rules when both behaviours are genuinely wanted.

`schedule_expression` is either `rate(...)` or `cron(...)`, and both
forms have a syntax worth catching early.
[AWS's cron expressions have six required fields](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-scheduled-rule-pattern.html),
not the five a Unix crontab uses — the sixth is a year — so a
five-field expression copied from a crontab is rejected. A rate
expression's unit is singular only for a value of 1, which makes
`rate(1 hours)` invalid where `rate(1 hour)` is valid. Both rules are
validated here rather than left to surface as an unhelpful *"Parameter
ScheduleExpression is not valid"* at apply.

AWS labels scheduled rules a legacy feature and recommends EventBridge
Scheduler for new work. A scheduled rule remains the right tool when the
schedule belongs beside event-driven rules on the same bus, or when the
target is one Scheduler does not support; reach for Scheduler when you
need one-time invocations, time zones other than UTC, or flexible
delivery windows.

### A failed invocation is discarded unless a target has a dead-letter queue

`retry_policy` and `dead_letter_arn` are configured **per target**, not
once for the rule. That follows AWS's own model: one rule can fan out to
a Lambda function worth retrying for hours and a queue worth abandoning
after a minute, and the two settings belong to the delivery rather than
to the match.

Without a dead-letter queue, EventBridge retries a failed invocation and
then **drops the event silently**. Nothing is logged that names the lost
event, and the only signal is the `FailedInvocations` metric going up.
Give any target whose events matter a queue from
[`terraform-aws-sqs-queue`](https://github.com/kn47ytv9mv/terraform-aws-sqs-queue)
and pass its `arn` output as `dead_letter_arn`.

**This module does not create the queue policy that queue needs.**
EventBridge writes to a dead-letter queue as the `events.amazonaws.com`
service principal, and an SQS queue denies that by default, so a queue
supplied here without a policy granting `sqs:SendMessage` to that
principal discards exactly the events it was added to preserve — see
AWS's
[Granting permissions to the dead-letter queue](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-rule-dlq.html).
Set that policy through the queue module's own `policy` input. Scope it
with an `aws:SourceArn` condition, and note that naming this module's
`arn` output in it creates a dependency cycle Terraform rejects: the
rule would wait on the queue's ARN while the queue waited on the rule's.
Construct the rule ARN as a literal string from the name you passed in,
or condition on `aws:SourceAccount` instead.

A retry policy's own ceilings are AWS's: at most 185 attempts, and an
event held at most 24 hours. Both of those are also the defaults, so a
target left unconfigured already retries generously — the gap this
module cannot close for you is the queue, not the retries.

### Which targets need a role and which do not

`role_arn` on a target is the role EventBridge assumes to perform the
invocation, and whether it is required depends entirely on the target
service:

- **Required** for ECS tasks, Step Functions state machines, Systems
  Manager Run Command, Batch jobs, Kinesis streams, API destinations,
  and any target in another account or Region. These services expose no
  resource policy for EventBridge to be granted through, so the
  permission has to arrive as an assumed role. Build it with
  [`terraform-aws-iam-role`](https://github.com/kn47ytv9mv/terraform-aws-iam-role),
  trusting `events.amazonaws.com`.
- **Ignored** for Lambda functions, SNS topics, and SQS queues. Each of
  those authorizes EventBridge through its own resource policy instead,
  and a role supplied here changes nothing.

This module validates the one case where the omission is unambiguous —
an `ecs_target` without `role_arn` — and leaves the rest to the target
service, because the remaining requirements depend on the ARN's service
rather than on anything the module can see.

### Shaping what a target receives

`input`, `input_path`, and `input_transformer` are mutually exclusive,
and supplying more than one is rejected here rather than at apply. They
answer the same question in three ways: `input` replaces the event with
a constant, `input_path` forwards one JSONPath-selected fragment of it,
and `input_transformer` extracts named paths and substitutes them into a
template. A target given none of the three receives the whole event.

### What this module does not cover

The event bus itself is not created here. `event_bus_name` names an
existing bus, whether the account default or a custom one, and a module
that created the bus alongside one rule would force every other rule on
that bus to be declared in the same call.

Neither does this module create the resource policies a Lambda, SNS, or
SQS target needs in order to accept the invocation — the
`aws_lambda_permission` for a function, or the queue and topic policies
naming `events.amazonaws.com`. Those belong to the target, which is
usually declared by a different module call and often in a different
state file.

## Usage

```hcl
module "nightly_report" {
  source = "kn47ytv9mv/eventbridge-rule/aws"

  name                = "nightly-report"
  description         = "Runs the nightly reporting job"
  schedule_expression = "cron(0 3 * * ? *)"

  targets = {
    report_builder = {
      arn = "arn:aws:lambda:us-east-1:123456789012:function:report-builder"
    }
  }
}
```

Or directly from this repository, responding to an AWS event and keeping
whatever could not be delivered:

```hcl
module "failed_invocations" {
  source = "github.com/kn47ytv9mv/terraform-aws-sqs-queue"

  name                      = "eventbridge-failed-invocations"
  message_retention_seconds = 1209600
}

module "instance_terminated" {
  source = "github.com/kn47ytv9mv/terraform-aws-eventbridge-rule"

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
      dead_letter_arn = module.failed_invocations.arn

      retry_policy = {
        maximum_retry_attempts       = 4
        maximum_event_age_in_seconds = 3600
      }
    }
  }
}
```

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.9 |
| aws | ~> 6.61 |
| random | ~> 3.9 |

## Providers

| Name | Version |
|---|---|
| aws | ~> 6.61 |
| random | ~> 3.9 |

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| name | Name of the rule, unique within its event bus, up to 64 characters of letters, digits, periods, hyphens, and underscores. If null, a unique name is generated. | `null` | no |
| schedule_expression | Schedule on which the rule fires, as `rate(5 minutes)` or `cron(0 3 * * ? *)`. Fires only on the default event bus, and AWS's cron takes six fields — see Design. | `null` | no |
| event_pattern | JSON pattern matched against events arriving on the bus. Exactly one of `schedule_expression` or `event_pattern` is required. | `null` | no |
| event_bus_name | Event bus the rule and its targets live on. If null, the account's default bus. A custom bus cannot carry a scheduled rule, and this module does not create the bus. | `null` | no |
| targets | Destinations invoked when the rule matches, keyed by a name you write literally, which becomes the target's `target_id`. Retries and dead-lettering are per target — see Design. | `{}` | no |
| description | Human-readable explanation of what the rule matches and why, up to 512 characters. | `null` | no |
| state | Whether the rule is active: `'ENABLED'`, `'DISABLED'`, or `'ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS'`. If null, AWS enables the rule. | `null` | no |
| role_arn | IAM role EventBridge assumes for the rule itself, which applies only when forwarding to a bus in another account or Region. A target's own role belongs on that target. | `null` | no |
| tags | A map of tags to assign to the rule. Targets carry no tags of their own. | `null` | no |

## Outputs

| Name | Description |
|---|---|
| id | The ID of the rule, which is its name, prefixed with the event bus name when the rule is on a custom bus. |
| arn | The ARN of the rule. A target's resource policy names this ARN as the source permitted to invoke it. |
| name | The name of the rule, generated when `name` was left unset. |

## License

MIT — see [LICENSE.md](LICENSE.md).
