# Deployment-owned projection of Dédalo's product registry. Missing/invalid
# configuration exposes no stages and grants no producer privileges.
class TickHealth::Registry
  IDENTIFIER = /\A[a-z0-9][a-z0-9._:-]{0,99}\z/

  def self.for(board)
    path = ENV["TICK_HEALTH_REGISTRY_FILE"]
    return unless path.present?

    document = JSON.parse(File.binread(path, 256.kilobytes + 1))
    return unless document.is_a?(Hash) && document.keys.sort == %w[ products schema ] && document["schema"].is_a?(Integer) && document["schema"] == 1
    products = document["products"]
    return unless products.is_a?(Array) && products.size <= 100
    return unless products.all? { valid_product?(it) }
    return unless products.map { it["id"] }.uniq.size == products.size
    return unless products.map { [ it["account_id"], it["board_id"] ] }.uniq.size == products.size

    products.find { it["account_id"] == board.account.external_account_id.to_s && it["board_id"] == board.id }
  rescue JSON::ParserError, SystemCallError, IOError, ArgumentError
    nil
  end

  def self.valid_product?(product)
    return false unless product.is_a?(Hash) && product.keys.sort == %w[ account_id board_id id producer_user_id stages ]
    return false unless %w[ id account_id board_id producer_user_id ].all? { product[it].is_a?(String) && product[it].match?(IDENTIFIER) }
    stages = product["stages"]
    stages.is_a?(Array) && stages.size <= 30 && stages.all? { valid_stage?(it) } &&
      stages.map { it["id"] }.uniq.size == stages.size && stages.map { it["column_id"] }.uniq.size == stages.size
  end

  def self.valid_stage?(stage)
    stage.is_a?(Hash) && stage.keys.sort == %w[ column_id description id ] &&
      %w[ id column_id ].all? { stage[it].is_a?(String) && stage[it].match?(IDENTIFIER) } &&
      stage["description"].is_a?(String) && stage["description"].size.between?(1, 200) &&
      Card::AutomaticWait::Declaration::SENSITIVE_TEXT.none? { stage["description"].match?(it) }
  end
end
