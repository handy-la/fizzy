# Handy: a playful page with the totals of what has shipped.
class LeaderboardsController < ApplicationController
  def show
    @leaderboard = Leaderboard.new(Current.user)
  end
end
