import { createContext, useContext } from 'react'

export const OvcsProductContext = createContext(null)

/** The dashboard's product name, as its `OvcsShell` gives it; `null` outside one that names it. */
export const useOvcsProduct = () => useContext(OvcsProductContext)
