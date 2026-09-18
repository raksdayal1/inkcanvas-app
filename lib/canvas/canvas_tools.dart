/// The tools available in the side toolbar. A stylus/mouse-drag performs
/// whichever action the active tool implies; touch is reserved for
/// navigation (pan/zoom) except when [select] is active, where a single
/// finger taps/drags to select and move content instead.
enum CanvasTool {
  pen,
  highlighter,
  eraser,
  shape,
  lasso,
  text,
  select,
  pan,
}

/// Which handle of a resizable element's bounding box a resize drag
/// started from - a corner (moves two edges) or a mid-edge handle (moves
/// just one edge/axis) - so we know which edges to move as the pointer
/// moves.
enum ResizeHandle { topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right }
