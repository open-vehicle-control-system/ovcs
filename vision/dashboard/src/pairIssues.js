/** The issues a pair check raises, as the unit names them (`VisionCore.Stereo.PairCheck`). */
export const PAIR_ISSUES = Object.freeze({
  TIMING_OFFSET: 'timing_offset',
  ROW_OFFSET: 'row_offset',
  LARGE_ROW_CORRECTION: 'large_row_correction',
  UNEVEN_ROWS: 'uneven_rows',
  FOCUS_MISMATCH: 'focus_mismatch'
})

/** What each issue means and what to do about it. */
export const ISSUE_WORDING = Object.freeze({
  [PAIR_ISSUES.TIMING_OFFSET]: 'Captures too far apart: check how the cameras are triggered',
  [PAIR_ISSUES.ROW_OFFSET]: 'Rows apart: recalibrate',
  [PAIR_ISSUES.LARGE_ROW_CORRECTION]: 'Rows held by a large correction: recalibrate',
  [PAIR_ISSUES.UNEVEN_ROWS]: 'Rows uneven across the image, a camera turned: recalibrate',
  [PAIR_ISSUES.FOCUS_MISMATCH]: 'Softer than the other camera: refocus it'
})

/** What to do about each issue, in a word or two, as the badge on the camera it concerns says it. */
export const ISSUE_ACTION = Object.freeze({
  [PAIR_ISSUES.TIMING_OFFSET]: 'Check timing',
  [PAIR_ISSUES.ROW_OFFSET]: 'Recalibrate',
  [PAIR_ISSUES.LARGE_ROW_CORRECTION]: 'Recalibrate',
  [PAIR_ISSUES.UNEVEN_ROWS]: 'Recalibrate',
  [PAIR_ISSUES.FOCUS_MISMATCH]: 'Refocus'
})

/** An issue's wording, its code where the dashboard does not know it yet. */
export const issueWording = (issue) => ISSUE_WORDING[issue] ?? issue

/** The actions `issues` call for, each once, in their order. */
export const issueActions = (issues) => [...new Set(issues.map((issue) => ISSUE_ACTION[issue] ?? issue))]
