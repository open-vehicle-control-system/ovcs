import { fireEvent, render, screen, within } from '@testing-library/react'
import { describe, expect, test, vi } from 'vitest'

import {
  OvcsMain,
  OvcsMenu,
  OvcsMenuItem,
  OvcsMenuList,
  OvcsMenuSection,
  OvcsPageFrame,
  OvcsShell,
  OvcsShellBody,
  OvcsTopBar,
  OvcsTopBarEnd,
  OvcsTopBarTitle
} from './index.js'

describe('the page frame', () => {
  test('puts the top bar over the menu and the main content', () => {
    render(
      <OvcsShell>
        <OvcsTopBar>
          <OvcsTopBarTitle product="Vision">
            <p>abc123</p>
          </OvcsTopBarTitle>
          <OvcsTopBarEnd>
            <span>Live</span>
          </OvcsTopBarEnd>
        </OvcsTopBar>
        <OvcsShellBody>
          <OvcsMenu label="Vision unit" />
          <OvcsMain>content</OvcsMain>
        </OvcsShellBody>
      </OvcsShell>
    )

    const heading = screen.getByRole('heading', { level: 1 })
    expect(heading.textContent).toBe('OVCS Vision')
    expect(heading.parentElement.textContent).toContain('abc123')
    expect(screen.getByRole('banner').classList).toContain('ovcs-header')
    expect(screen.getByRole('navigation', { name: 'Vision unit' })).toBeTruthy()
    expect(screen.getByRole('main').textContent).toBe('content')
  })
})

describe('OvcsMenu', () => {
  test('names each section by its title and marks the selected item as the current page', () => {
    const onClick = vi.fn()
    render(
      <OvcsMenu label="Bus">
        <OvcsMenuSection title="Nodes">
          <OvcsMenuList label="Nodes">
            <li>
              <OvcsMenuItem selected>vms</OvcsMenuItem>
            </li>
            <li>
              <OvcsMenuItem onClick={onClick}>bridge-ros</OvcsMenuItem>
            </li>
          </OvcsMenuList>
        </OvcsMenuSection>
      </OvcsMenu>
    )

    const section = screen.getByRole('region', { name: 'Nodes' })
    const [vms, ros] = within(within(section).getByRole('list', { name: 'Nodes' })).getAllByRole('button')
    expect(vms.getAttribute('aria-current')).toBe('page')
    expect(vms.className).toContain('shadow-[inset_3px_0_0_var(--ovcs-accent)]')
    expect(ros.getAttribute('aria-current')).toBeNull()
    expect(ros.className).toContain('hover:bg-ovcs-bg')
    fireEvent.click(ros)
    expect(onClick).toHaveBeenCalled()
  })

  test('lets an item name another kind of current entry', () => {
    render(
      <OvcsMenuItem selected aria-current="true">
        Cameras
      </OvcsMenuItem>
    )
    expect(screen.getByRole('button').getAttribute('aria-current')).toBe('true')
  })
})

describe('OvcsPageFrame', () => {
  test('heads its content with the title and the summary', () => {
    render(
      <OvcsPageFrame title="ROS 2" summary="What this unit publishes.">
        <p>topics</p>
      </OvcsPageFrame>
    )
    expect(screen.getByRole('heading', { level: 2 }).textContent).toBe('ROS 2')
    expect(screen.getByText('What this unit publishes.')).toBeTruthy()
    expect(screen.getByText('topics')).toBeTruthy()
  })
})
