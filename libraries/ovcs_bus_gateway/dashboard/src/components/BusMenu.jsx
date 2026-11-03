import { OvcsMenu, OvcsMenuItem, OvcsMenuList, OvcsMenuSection } from '@ovcs/ui/react'

import { nodeStatus, signalCount } from '../signals'
import { STATUS_DOT } from './statusDot'

function Count({ children }) {
  return <span className="ml-auto text-xs tabular-nums text-ovcs-muted">{children}</span>
}

/** The whole bus, then each node with its status and how many signals it publishes; `selected` is a node's name. */
export default function BusMenu({ bus, count, selected, onSelect }) {
  return (
    <OvcsMenu label="Bus gateway">
      <OvcsMenuSection title="Main">
        <OvcsMenuList label="Main">
          <li>
            <OvcsMenuItem selected={selected == null} onClick={() => onSelect(null)}>
              Bus
              <Count>{count}</Count>
            </OvcsMenuItem>
          </li>
        </OvcsMenuList>
      </OvcsMenuSection>
      <OvcsMenuSection title="Nodes">
        <OvcsMenuList label="Nodes">
          {bus.map((node) => {
            const status = nodeStatus(node)
            return (
              <li key={node.node}>
                <OvcsMenuItem selected={selected === node.node} title={status.label} onClick={() => onSelect(node.node)}>
                  <span aria-hidden="true" className={STATUS_DOT[status.tone]} />
                  <span className="min-w-0 truncate" translate="no">
                    {node.node}
                  </span>
                  <span className="sr-only">, {status.label}</span>
                  <Count>{signalCount(node)}</Count>
                </OvcsMenuItem>
              </li>
            )
          })}
        </OvcsMenuList>
      </OvcsMenuSection>
    </OvcsMenu>
  )
}
