require "test_helper"

# Handy #2304. Contract, regression, coverage and seam: docs/test-audits/handy-2304.md.
class Card::PendingRequestTest < ActiveSupport::TestCase
  MARKER = Card::PendingRequest::MARKER

  setup do
    Current.session = sessions(:david)
    @card = cards(:text)
    @card.comments.destroy_all
    @at = 1.hour.ago
  end

  test "progress comments from Dédalo are not a pending request" do
    dedalo "📌 Recibida como handy-3."
    dedalo "🛠️ Trabajando en la rama."
    dedalo "✅ Encontré la causa."

    assert_equal :none, pending.status
  end

  test "a marked question is pending, and later progress keeps it open" do
    question = dedalo "❓ ¿Guardo el historial completo o sólo el último mes?"
    dedalo "📌 Sigo con lo que no depende de la respuesta."

    assert pending.pending?
    assert_equal [ question ], pending.requests
  end

  test "an agent's question and Dédalo's wait notice stay open together" do
    asked = dedalo "⚠️ La búsqueda falló.\n\n❓ ¿Pueden restablecerla?"
    notice = dedalo "❓ El agente espera tu respuesta a la pregunta que dejó en la tarjeta."

    assert pending.pending?
    assert_equal [ asked, notice ], pending.requests
  end

  test "a person's comment answers every open question" do
    dedalo "❓ ¿Uno o dos?"
    dedalo "❓ El agente espera tu respuesta."
    human "Uno."

    assert_equal :none, pending.status
  end

  test "a new question after an answer is the only one open" do
    dedalo "❓ ¿Uno o dos?"
    human "Uno."
    second = dedalo "❓ ¿Y el color?"

    assert_equal [ second ], pending.requests
  end

  test "Dédalo's warning right after an answer reopens the question for review" do
    question = dedalo "❓ ¿Qué opción?"
    human "Creo que la primera, pero no estoy seguro."
    dedalo "⚠️ No tomé tu comentario como respuesta: falta contestar la pregunta 2."

    assert pending.review?
    assert_equal :warning_after_answer, pending.reason_code
    assert_equal [ question ], pending.requests
  end

  test "a warning long after an answer, with progress in between, does not reopen it" do
    dedalo "❓ ¿Qué opción?"
    human "La primera."
    dedalo "📌 Sigo con la primera opción."
    dedalo "⚠️ La CI tardó más de lo normal."

    assert_equal :none, pending.status
  end

  test "an expired question is not pending" do
    dedalo "❓ ¿Qué opción?"
    dedalo "⌛ La pregunta venció tras 24 horas sin respuesta."

    assert_equal :none, pending.status
  end

  test "a newer version of the same Dédalo question replaces the older one" do
    dedalo "❓ **El agente te hace una pregunta.** pregunta `q-handy-3-a1-0123456789ab-v1`"
    newer = dedalo "❓ **El agente te hace una pregunta.** pregunta `q-handy-3-a1-0123456789ab-v2`"

    assert_equal [ newer ], pending.requests
  end

  test "an unmarked comment from the account that asks needs review, not an answer" do
    question = dedalo "❓ ¿Qué opción?"
    comment :jz, "Coordino con la otra tarjeta."

    assert pending.review?
    assert_equal :requester_unmarked, pending.reason_code
    assert_equal [ question ], pending.requests
  end

  test "an approval stage with no open question needs review" do
    @card.update!(column: approval_column)
    summary = dedalo "✅ Listo para revisión."

    assert pending.review?
    assert_equal :approval_without_question, pending.reason_code
    assert_equal [ summary ], pending.requests
  end

  test "an automatic wait alone, outside the approval stage, is not pending" do
    dedalo "⏳ Espero a que termine la CI."

    assert_equal :none, pending.status
  end

  test "a question still open wins over an automatic wait noted after it" do
    question = dedalo "❓ ¿Despliego hoy?"
    dedalo "⏳ Espero a que termine la CI."

    assert_equal [ question ], pending.requests
  end

  test "system comments between the question and now change nothing" do
    question = dedalo "❓ ¿Qué opción?"
    comment :system, "Hermes moved this to AWAITING APPROVAL"

    assert_equal [ question ], pending.requests
  end

  test "a closed card has nothing pending" do
    dedalo "❓ ¿Qué opción?"
    @card.close

    assert_equal :none, pending.status
  end

  test "a quoted marker in the middle of a person's comment is not Dédalo's" do
    dedalo "❓ ¿Qué opción?"
    human "Copio lo que dijo: «❓ ¿Qué opción?#{MARKER}» y contesto: la primera."

    assert_equal :none, pending.status
  end

  test "the fingerprint changes when a comment arrives" do
    dedalo "❓ ¿Qué opción?"
    before = pending.fingerprint
    dedalo "📌 Progreso."

    assert_not_equal before, pending.fingerprint
  end

  private
    def pending
      Card::PendingRequest.for(@card.reload)
    end

    def dedalo(text)
      comment :jz, text + MARKER
    end

    def human(text)
      comment :david, text
    end

    def comment(user, text)
      @at += 1.minute
      @card.comments.create!(body: text, created_at: @at, creator: users(user))
    end

    def approval_column
      columns(:writebook_review).tap { |column| column.update!(name: "AWAITING APPROVAL") }
    end
end
