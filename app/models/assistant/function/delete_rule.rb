# frozen_string_literal: true

# DeleteRule — deletes a rule, like the delete button in Settings > Rules. A
# call without preview_token deletes nothing and returns the rule plus a token;
# only a call with that token deletes (see PreviewToken).
class Assistant::Function::DeleteRule < Assistant::Function
  include Assistant::Function::RuleSupport

  annotate :destructive, idempotent: true

  class << self
    def name
      "delete_rule"
    end

    def description
      <<~INSTRUCTIONS
        Deletes a transaction rule from get_rules. This cannot be undone: its
        conditions, actions and run history are deleted with it. Changes the
        rule already made to transactions are kept.

        Always two calls. First call it without preview_token: nothing is
        deleted, and it returns the rule (including whether it is active), how
        many runs its history holds, and a preview_token. Show that to the
        user, and only once they confirm call it again with the same rule_id
        and that preview_token. The token expires after
        #{Assistant::Function::PreviewToken::PREVIEW_TOKEN_TTL.inspect} and is refused if the rule changed since the preview.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[rule_id],
      properties: {
        rule_id: {
          type: "string",
          description: "Rule ID from get_rules."
        },
        preview_token: {
          type: "string",
          description: "preview_token from the preview call with the same rule_id. Omit it to preview; nothing is deleted without it."
        }
      }
    )
  end

  def call(params = {})
    rule = find_rule(params["rule_id"])
    return error("not_found", "No rule with id '#{params["rule_id"]}'.") unless rule

    return delete(params, rule) if params["preview_token"].blank?

    # A rule run loads its rules up front and applies them without checking
    # active again, so a rule is only deleted while no run is in progress.
    result = nil
    acquired = Rule::Runner.with_family_lock(family.id) { result = delete(params, rule) }
    return error("rules_running", "Rules are running for this family right now. Try again in a minute.") unless acquired

    result
  end

  private
    def delete(params, rule)
      confirm_with_preview(params, rule, -> { deletion_preview(rule) }) do |shown|
        rule.destroy!

        name = rule.name.present? ? "Rule '#{rule.name}'" : "Rule"
        { success: true, deleted: true, rule: shown[:rule], message: "#{name} deleted. Its run history was deleted with it." }
      end
    end

    # What deleting the rule removes; the token is bound to it. Conditions and
    # actions load in no fixed order, so they are sorted to keep the digest
    # stable between the preview and the confirming call.
    def deletion_preview(rule)
      serialized = serialize_rule(rule)
      serialized[:conditions] = serialized[:conditions].sort_by(&:to_json)
      serialized[:actions] = serialized[:actions].sort_by(&:to_json)
      { rule: serialized, run_count: rule.rule_runs.count }
    end
end
