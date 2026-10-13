require "test_helper"

# Contract (Handy #965): a revocation that another actor committed on the writer takes effect on the next
# request, even when the replica that serves reads has not applied it yet. The reads that decide who the
# request is — session, identity, user, role, staff flag and account state — run on the writer.
# Authoring answers and RED evidence: docs/test-audits/handy-965.md.
class ReplicaRevocationTest < ActionDispatch::IntegrationTest
  StaleUsers = Struct.new(:user) do
    def find_by(*) = user
  end

  test "a user deactivated from another session is refused while the replica still has them active" do
    sign_in_as :david
    stale_user = User.find(users(:david).id)
    users(:david).deactivate

    lagging_replica Identity, :users, ->(_) { StaleUsers.new(stale_user) } do
      get boards_path, as: :json
    end

    assert_response :forbidden
  end

  test "a bearer token of a deactivated user is refused while the replica still has them active" do
    stale_user = User.find(users(:david).id)
    users(:david).deactivate

    lagging_replica Identity, :users, ->(_) { StaleUsers.new(stale_user) } do
      get boards_path, as: :json, env: { "HTTP_AUTHORIZATION" => "Bearer #{identity_access_tokens(:davids_api_token).token}" }
    end

    assert_response :forbidden
  end

  test "an admin demoted from another session loses admin access while the replica still has the old role" do
    sign_in_as :kevin
    stale_user = User.find(users(:kevin).id)
    users(:kevin).update!(role: :member)

    lagging_replica Identity, :users, ->(_) { StaleUsers.new(stale_user) } do
      get board_webhooks_path(boards(:writebook))
    end

    assert_response :forbidden
  end

  test "a staff flag removed from another session is refused while the replica still has it" do
    sign_in_as :david
    stale_identity = Identity.find(identities(:david).id)
    identities(:david).update!(staff: false)

    lagging_replica Session, :identity, ->(_) { stale_identity } do
      untenanted { get "/admin/jobs" }
    end

    assert_response :forbidden
  end

  test "an account cancelled from another session is refused while the replica still has it active" do
    sign_in_as :david
    accounts("37s").create_cancellation!(initiated_by: users(:jason))

    lagging_replica Account, :cancelled?, ->(_) { false } do
      get boards_path, as: :json
    end

    assert_response :forbidden
  end

  private
    # Simulates a replica behind the writer: outside ApplicationRecord.with_writing_role, klass#method answers
    # the stale value; inside it, the real one. The overrides live in prepended modules that are emptied after
    # the block, so they are inert for every later test in this process.
    def lagging_replica(klass, method, stale)
      on_writer = false
      writer = Module.new do
        define_method(:with_writing_role) do |&block|
          previous, on_writer = on_writer, true
          super(&block)
        ensure
          on_writer = previous
        end
      end
      replica = Module.new do
        define_method(method) do |*args, **kwargs, &block|
          on_writer ? super(*args, **kwargs, &block) : stale.call(self)
        end
      end

      ApplicationRecord.singleton_class.prepend(writer)
      klass.prepend(replica)
      yield
    ensure
      writer.remove_method(:with_writing_role)
      replica.remove_method(method)
    end
end
