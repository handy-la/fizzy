# RubyLLM en Fizzy Custom

RubyLLM 2.0 está instalado en los dos Gemfiles. Usa Fireworks AI por su API
compatible con OpenAI Chat Completions. El token llega por `FIREWORKS_API_KEY`
o por `/run/secrets/fireworks_api_key` en el contenedor local. La clave no vive
en el repositorio. El inicializador no necesita la clave para arrancar Fizzy;
una consulta sin clave falla en RubyLLM.

El modelo predeterminado es el alias sin fecha
`accounts/fireworks/routers/deepseek-flash-latest`. RubyLLM aún no lo incluye
en su catálogo, por lo que cada chat debe indicar el proveedor y omitir la
validación del catálogo:

```ruby
RubyLLM.chat(
  provider: :openai,
  protocol: :chat_completions,
  assume_model_exists: true
).ask("Responde solo OK.").content
```

El protocolo explícito es necesario: RubyLLM 2.0 usa Responses por defecto
para OpenAI, pero Fireworks recibe esta consulta por Chat Completions. El alias
es de Fireworks; `deepseek-flash` a secas es un nombre de la API de DeepSeek y
no identifica el mismo proveedor.

Por ahora no hay interfaz, historial ni herramientas de IA en Fizzy. La llamada
anterior desde `bin/rails console` comprueba la integración. Una llamada real
consume tokens; el arranque de la aplicación no llama al modelo.
