# Handy: direct links to the other boards, as small badges on either side of
# the board menu, so switching boards takes one tap instead of opening the menu.
module My::BoardLinksHelper
  BOARD_LINKS_LIMIT = 10

  def header_board_links(current_board)
    boards = Current.user.boards.alphabetically.where.not(id: current_board).limit(BOARD_LINKS_LIMIT).to_a
    half = (boards.size + 1) / 2
    [ boards.first(half), boards.drop(half) ]
  end

  def header_board_link(board)
    link_to board.name, board, class: "header__board-link overflow-ellipsis", title: board.name, data: { turbo_frame: "_top" }
  end
end
