import { describe, expect, it } from 'vitest'
import { DEPTH_ISSUES, ISSUE_ACTION, ISSUE_WORDING, PAIR_ISSUES, issueWording } from '../issues.js'

describe('issues', () => {
  it('words every issue the unit raises, and names what to do about it', () => {
    for (const issue of [...Object.values(PAIR_ISSUES), ...Object.values(DEPTH_ISSUES)]) {
      expect(ISSUE_WORDING[issue]).toBeTruthy()
      expect(ISSUE_ACTION[issue]).toBeTruthy()
    }
  })

  it("shows an issue it does not know by the unit's code", () => {
    expect(issueWording('new_issue')).toBe('new_issue')
  })
})
