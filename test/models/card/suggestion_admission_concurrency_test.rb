require "test_helper"

class Card::SuggestionAdmissionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    Card::SuggestionRequest.delete_all
    Card::SuggestionAdmission.delete_all if defined?(Card::SuggestionAdmission)
    Card::SuggestionQueue.delete_all if defined?(Card::SuggestionQueue)
  end

  test "concurrent admissions on different cards share the same user slot" do
    ready, release, outcomes = Queue.new, Queue.new, Queue.new
    threads = [ cards(:logo), cards(:text) ].map do |card|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          begin
            Card::SuggestionRequest.request(card, user: users(:kevin), kind: "comment")
            outcomes << :accepted
          rescue => error
            outcomes << (error.class.name == "Card::SuggestionQueue::Full" ? :rejected : error)
          ensure
            Current.clear_all
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:join)

    assert_equal [ :accepted, :rejected ], 2.times.map { outcomes.pop }.sort_by(&:to_s)
    assert_equal 1, Card::SuggestionRequest.where(status: "pending").count
    assert_equal 1, Card::SuggestionAdmission.count if defined?(Card::SuggestionAdmission)
    assert_enqueued_jobs 1, only: Card::SuggestionJob
  ensure
    threads&.each { |thread| thread.join(10) }
  end
end
