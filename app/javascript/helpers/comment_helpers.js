// Room left above the last comment, so its author line is not flush with the top edge.
const LAST_COMMENT_MARGIN = 16

// Each comment sits in its own frame; a highlighted code comment inside one also has
// the class "comment". Older system comments stay hidden until the history is
// expanded: skip them.
export function lastVisibleComment() {
  const comments = document.querySelectorAll(".comments > turbo-frame > .comment")
  return Array.from(comments).findLast(comment => comment.getClientRects().length > 0)
}

// Lands on the start of the comment, not its end: a long comment is read from its top.
// `below` is room taken at the top by something fixed, such as the card's title bar.
export function scrollToComment(comment, behavior, { below = 0 } = {}) {
  const top = comment.getBoundingClientRect().top + window.scrollY - LAST_COMMENT_MARGIN - below
  window.scrollTo({ top, behavior })
}
