require "test_helper"

class Assistant::Function::DeleteRuleTest < ActiveSupport::TestCase
  include FamilyLockTestHelper
  include PreviewTokenTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::DeleteRule.new(@user)
    @category = categories(:food_and_drink)

    @rule = @family.rules.create!(
      name: "Coffee",
      resource_type: "transaction",
      active: true,
      conditions_attributes: [
        { condition_type: "transaction_name", operator: "like", value: "zxq coffee" },
        { condition_type: "transaction_name", operator: "like", value: "zxq espresso" }
      ],
      actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
    )
  end

  test "without a preview_token it previews the deletion and deletes nothing" do
    result = @fn.call("rule_id" => @rule.id)

    assert_equal true, result[:success]
    assert_equal false, result[:deleted]
    assert_equal "Coffee", result.dig(:preview, :rule, :name)
    assert_equal true, result.dig(:preview, :rule, :active)
    assert_equal 0, result.dig(:preview, :run_count)
    assert result[:preview_token].present?
    assert Rule.exists?(@rule.id)
  end

  test "deletes an active rule with its conditions, actions and runs with the token from its preview, and returns what it deleted" do
    @rule.rule_runs.create!(execution_type: "manual", status: "success", transactions_queued: 1, transactions_processed: 1, transactions_modified: 1, executed_at: Time.current)
    condition_ids = @rule.conditions.ids
    action_ids = @rule.actions.ids

    result = delete_with_preview

    assert result[:success], result.inspect
    assert result[:deleted]
    assert_equal @rule.id, result.dig(:rule, :id)
    assert_equal "set_transaction_category", result.dig(:rule, :actions, 0, :action_type)
    assert_match "Rule 'Coffee' deleted", result[:message]
    assert_not Rule.exists?(@rule.id)
    assert_empty Rule::Condition.where(id: condition_ids)
    assert_empty Rule::Action.where(id: action_ids)
    assert_empty RuleRun.where(rule_id: @rule.id)
  end

  test "refuses a token once the rule changed, and returns a fresh preview" do
    token = @fn.call("rule_id" => @rule.id)[:preview_token]
    @rule.update!(active: false)

    result = @fn.call("rule_id" => @rule.id, "preview_token" => token)

    assert_equal "preview_stale", result[:error]
    assert_equal false, result.dig(:preview, :rule, :active)
    assert result[:preview_token].present?
    assert Rule.exists?(@rule.id)
  end

  test "refuses a token once the rule changed after the token was checked" do
    token = @fn.call("rule_id" => @rule.id)[:preview_token]
    change_after_token_check(@fn) { Rule.where(id: @rule.id).update_all(name: "Tea") }

    result = @fn.call("rule_id" => @rule.id, "preview_token" => token)

    assert_equal "preview_stale", result[:error]
    assert Rule.exists?(@rule.id)
  end

  test "a rule deleted by another call after the token was checked is not found" do
    token = @fn.call("rule_id" => @rule.id)[:preview_token]
    change_after_token_check(@fn) { Rule.find(@rule.id).destroy! }

    assert_equal "not_found", @fn.call("rule_id" => @rule.id, "preview_token" => token)[:error]
  end

  test "refuses while a rule run holds the family lock and leaves the rule in place" do
    token = @fn.call("rule_id" => @rule.id)[:preview_token]

    with_family_lock_held_elsewhere(@family.id, key: Rule::Runner.advisory_lock_key(@family.id)) do
      assert_equal "rules_running", @fn.call("rule_id" => @rule.id, "preview_token" => token)[:error]
    end
    assert Rule.exists?(@rule.id)
  end

  test "refuses a forged token, another rule's token, another user's token and an expired one" do
    other_rule = @family.rules.create!(
      name: "Other", resource_type: "transaction", active: false,
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq other" } ],
      actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
    )
    other_token = @fn.call("rule_id" => other_rule.id)[:preview_token]
    member_token = Assistant::Function::DeleteRule.new(users(:family_member)).call("rule_id" => @rule.id)[:preview_token]
    apply_token = Assistant::Function::PreviewRule.new(@user).call("rule_id" => @rule.id).dig(:preview, :preview_token)
    assert [ other_token, member_token, apply_token ].all?(&:present?)

    [ "forged", other_token, member_token, apply_token ].each do |token|
      assert_equal "preview_required", @fn.call("rule_id" => @rule.id, "preview_token" => token)[:error]
    end

    token = @fn.call("rule_id" => @rule.id)[:preview_token]
    travel Assistant::Function::PreviewToken::PREVIEW_TOKEN_TTL + 1.minute do
      assert_equal "preview_required", @fn.call("rule_id" => @rule.id, "preview_token" => token)[:error]
    end
    assert Rule.exists?(@rule.id)
  end

  test "another family's rule is not found and left untouched" do
    other_rule = families(:empty).rules.create!(
      name: "Theirs",
      resource_type: "transaction",
      active: false,
      actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
    )

    assert_equal "not_found", @fn.call("rule_id" => other_rule.id)[:error]
    assert Rule.exists?(other_rule.id)
  end

  test "unknown and malformed ids are not found" do
    [ "00000000-0000-0000-0000-000000000000", "not-a-uuid", "", nil ].each do |id|
      assert_equal "not_found", @fn.call("rule_id" => id)[:error], id.inspect
    end
  end

  private
    def delete_with_preview
      token = @fn.call("rule_id" => @rule.id)[:preview_token]
      @fn.call("rule_id" => @rule.id, "preview_token" => token)
    end
end
