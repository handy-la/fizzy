# Handy #2348: the read-only work map of every product the person can see.
# A GET that writes nothing; the graph reaches the page already filtered by
# the person's access (WorkMap) and through an allow-list (WorkMapsHelper).
class WorkMapsController < ApplicationController
  def show
    @work_map = WorkMap.new(user: Current.user)
  end
end
