class Session < ApplicationRecord
  belongs_to :identity
  has_many :push_subscriptions, class_name: "Push::Subscription", dependent: :delete_all
end
