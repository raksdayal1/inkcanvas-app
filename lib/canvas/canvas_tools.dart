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

/// Font choices offered for text boxes: a display label mapped to a
/// Google Fonts family name (via the google_fonts package, so the same
/// font actually renders the same way on both Windows and Android
/// instead of depending on whatever happens to be installed on the OS).
/// All single-word family names from the Google Fonts catalog, picked to
/// read as clearly different styles: a workhorse sans, a serif, a
/// monospace, and a handwritten-style font.
///
/// No separate "Default" entry - kDefaultTextFont (Sans Serif) *is* the
/// default, so a text box that's never been restyled just starts on
/// that entry already selected instead of on a redundant extra choice
/// that looks the same.
const Map<String, String> kTextFontChoices = {
  'Sans Serif': kDefaultTextFont,
  'Serif': 'Tinos',
  'Monospace': 'Cousine',
  'Handwritten': 'Caveat',
};

/// What a text box's null/unset fontFamily (new text boxes, and ones
/// saved before this feature existed) effectively renders as.
const String kDefaultTextFont = 'Roboto';
