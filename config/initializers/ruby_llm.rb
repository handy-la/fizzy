# Fireworks uses the OpenAI Chat Completions protocol. Keep this provider
# limited to chat; other RubyLLM operations have no Fireworks model configured.
fireworks_api_key = if File.file?("/run/secrets/fireworks_api_key")
  File.read("/run/secrets/fireworks_api_key").strip
else
  ENV["FIREWORKS_API_KEY"]
end

RubyLLM.configure do |config|
  config.openai_api_key = fireworks_api_key
  config.openai_api_base = "https://api.fireworks.ai/inference/v1"
  config.default_model = "accounts/fireworks/routers/kimi-k3-fast"
end
