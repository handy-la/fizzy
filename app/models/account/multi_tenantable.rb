module Account::MultiTenantable
  extend ActiveSupport::Concern

  class SignupsClosed < StandardError; end

  included do
    cattr_accessor :multi_tenant, default: false
  end

  class_methods do
    def accepting_signups?(lock: false)
      multi_tenant || Account.uncached { (lock ? Account.lock : Account.all).none? }
    end

    private
      def with_signup_permission(&block)
        if multi_tenant
          transaction(&block)
        else
          raise Account::SignupsClosed unless accepting_signups?

          Account::SignupLock.synchronize do
            raise Account::SignupsClosed unless accepting_signups?(lock: true)
            yield
          end
        end
      end
  end
end
