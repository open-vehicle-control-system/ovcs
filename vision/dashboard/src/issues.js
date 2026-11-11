/** The issues a pair check raises, as the unit names them (`VisionCore.Stereo.PairCheck`). */
export const PAIR_ISSUES = Object.freeze({
  TIMING_OFFSET: 'timing_offset',
  ROW_OFFSET: 'row_offset',
  LARGE_ROW_CORRECTION: 'large_row_correction',
  UNEVEN_ROWS: 'uneven_rows',
  FOCUS_MISMATCH: 'focus_mismatch',
  BRIGHTNESS_MISMATCH: 'brightness_mismatch'
})

/** The issues a depth check raises, as the unit names them (`VisionCore.Stereo.DepthCheck`). */
export const DEPTH_ISSUES = Object.freeze({
  PAIRS_DROPPED: 'pairs_dropped',
  TOO_NEAR: 'too_near'
})

/** What each issue means and what to do about it. */
export const ISSUE_WORDING = Object.freeze({
  [PAIR_ISSUES.TIMING_OFFSET]: 'Captures too far apart: check how the cameras are triggered',
  [PAIR_ISSUES.ROW_OFFSET]: 'Rows apart: recalibrate',
  [PAIR_ISSUES.LARGE_ROW_CORRECTION]: 'Rows held by a large correction: recalibrate',
  [PAIR_ISSUES.UNEVEN_ROWS]: 'Rows uneven across the image, a camera turned: recalibrate',
  [PAIR_ISSUES.FOCUS_MISMATCH]: 'Softer than the other camera: refocus it',
  [PAIR_ISSUES.BRIGHTNESS_MISMATCH]: 'Brighter than the other camera, as through a hazy lens: clean or check its lens',
  [DEPTH_ISSUES.PAIRS_DROPPED]: 'Pairs dropped, depth slower than the cameras: lower their frame rate or the stereo work',
  [DEPTH_ISSUES.TOO_NEAR]: 'Much of the scene nearer than the depth measures: move back or widen the disparity range'
})

/** What to do about each issue, in a word or two, as the badge on the preview it concerns says it. */
export const ISSUE_ACTION = Object.freeze({
  [PAIR_ISSUES.TIMING_OFFSET]: 'Check timing',
  [PAIR_ISSUES.ROW_OFFSET]: 'Recalibrate',
  [PAIR_ISSUES.LARGE_ROW_CORRECTION]: 'Recalibrate',
  [PAIR_ISSUES.UNEVEN_ROWS]: 'Recalibrate',
  [PAIR_ISSUES.FOCUS_MISMATCH]: 'Refocus',
  [PAIR_ISSUES.BRIGHTNESS_MISMATCH]: 'Check lens',
  [DEPTH_ISSUES.PAIRS_DROPPED]: 'Lower frame rate',
  [DEPTH_ISSUES.TOO_NEAR]: 'Too near'
})

/** An issue's wording, its code where the dashboard does not know it yet. */
export const issueWording = (issue) => ISSUE_WORDING[issue] ?? issue

/** The actions `issues` call for, each once, in their order. */
export const issueActions = (issues) => [...new Set(issues.map((issue) => ISSUE_ACTION[issue] ?? issue))]
