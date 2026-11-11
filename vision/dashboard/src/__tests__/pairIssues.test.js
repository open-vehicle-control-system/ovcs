import { describe, expect, it } from 'vitest'
import { ISSUE_WORDING, PAIR_ISSUES, issueWording } from '../pairIssues.js'

describe('pair issues', () => {
  it('words every issue the unit raises', () => {
    for (const issue of Object.values(PAIR_ISSUES)) expect(ISSUE_WORDING[issue]).toBeTruthy()
  })

  it("shows an issue it does not know by the unit's code", () => {
    expect(issueWording('new_issue')).toBe('new_issue')
  })
})
