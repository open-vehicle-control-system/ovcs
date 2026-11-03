import { OvcsMenu, OvcsMenuItem, OvcsMenuList, OvcsMenuSection } from '@ovcs/ui/react'

import { nodeStatus, signalCount } from '../signals'
import { LEVEL_TONE, STATUS_DOT } from './statusDot'

function Count({ children }) {
  return <span className="ml-auto text-xs tabular-nums text-ovcs-muted">{children}</span>
}

/**
 * The whole bus, each node with its status and how many signals it publishes, then the gateway's adapters with
 * theirs. `selection` is the selected node or adapter.
 */
export default function BusMenu({ bus, count, adapters, selection, onSelectNode, onOpenAdapter }) {
  return (
    <OvcsMenu label="Bus gateway">
      <OvcsMenuSection title="Main">
        <OvcsMenuList label="Main">
          <li>
            <OvcsMenuItem selected={selection.node == null && selection.adapter == null} onClick={() => onSelectNode(null)}>
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
                <OvcsMenuItem selected={selection.node === node.node} title={status.label} onClick={() => onSelectNode(node.node)}>
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
      <OvcsMenuSection title="Adapters">
        <OvcsMenuList label="Adapters">
          {(adapters ?? []).map((adapter) => (
            <li key={adapter.id}>
              <OvcsMenuItem
                selected={selection.adapter === adapter.id}
                title={adapter.status.detail}
                onClick={() => onOpenAdapter(adapter.id)}
              >
                <span aria-hidden="true" className={STATUS_DOT[LEVEL_TONE[adapter.status.level]]} />
                <span translate="no">{adapter.name}</span>
                <span className="sr-only">, {adapter.status.detail}</span>
              </OvcsMenuItem>
            </li>
          ))}
        </OvcsMenuList>
      </OvcsMenuSection>
    </OvcsMenu>
  )
}
