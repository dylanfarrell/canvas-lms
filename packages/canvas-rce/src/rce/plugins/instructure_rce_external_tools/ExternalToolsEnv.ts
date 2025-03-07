/*
 * Copyright (C) 2023 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import type {Editor} from 'tinymce'
import type {ExternalToolsEditor, RCEWrapperInterface, RCEWrapperProps} from '../../types'
import RCEWrapper from '../../RCEWrapper'
import {fallbackIframeAllowances} from './constants'

/**
 * Type of the "editor buttons" that come from Canvas.
 *
 * They're actually the available LTI Tool configurations, so we give them a more reasonable name here.
 */
export type RceLtiToolInfo = NonNullable<NonNullable<RCEWrapperProps['ltiTools']>[number]>

export interface ExternalToolsEnv {
  editor: ExternalToolsEditor | null
  rceWrapper: RCEWrapperInterface | null

  availableRceLtiTools: RceLtiToolInfo[]
  contextAssetInfo: {
    contextType: string
    contextId: string
  } | null
  resourceSelectionUrlOverride: string | null
  ltiIframeAllowPolicy: string
  isA2StudentView: boolean
  maxMruTools: number
  canvasOrigin: string
  containingCanvasLtiToolId: string | null
  editorSelection: string | null
  editorContent: string | null

  // @ts-expect-error
  insertCode(code: string)
  // @ts-expect-error
  replaceCode(code: string)
}

/**
 * Gets the environment information for the external tools dialog for a given tinyMCE editor.
 */
export function externalToolsEnvFor(
  editor: ExternalToolsEditor | null | undefined,
): ExternalToolsEnv {
  const props: () => RCEWrapperProps | undefined = () =>
    (RCEWrapper.getByEditor(editor as Editor)?.props as RCEWrapperProps) ?? undefined
  let cachedCanvasToolId: string | null | undefined

  function nonNullishArray<T>(
    arr: Array<T | null | undefined> | null | undefined,
  ): T[] | null | undefined {
    return arr?.filter(it => it != null) as T[]
  }

  return {
    editor: editor ?? null,

    get rceWrapper() {
      return RCEWrapper.getByEditor(editor as Editor) ?? null
    },

    get availableRceLtiTools(): RceLtiToolInfo[] {
      return nonNullishArray(props()?.ltiTools) ?? []
    },

    /**
     * Gets information about the context in which the editor is launched.
     */
    get contextAssetInfo(): {
      contextType: string
      contextId: string
    } | null {
      const trayProps = props()?.trayProps

      if (trayProps != null) {
        const {contextId, contextType} = trayProps.containingContext ?? trayProps

        if (
          contextId != null &&
          contextId.length > 0 &&
          contextType != null &&
          contextType.length > 0
        ) {
          return {contextType, contextId}
        }
      }

      return null
    },

    get resourceSelectionUrlOverride(): string | null {
      return props()?.externalToolsConfig?.resourceSelectionUrlOverride ?? null
    },

    get ltiIframeAllowPolicy(): string {
      return (
        nonNullishArray(props()?.externalToolsConfig?.ltiIframeAllowances) ??
        fallbackIframeAllowances
      ).join('; ')
    },

    get isA2StudentView(): boolean {
      return props()?.externalToolsConfig?.isA2StudentView ?? false
    },

    get maxMruTools(): number {
      return props()?.externalToolsConfig?.maxMruTools ?? 5
    },

    get canvasOrigin() {
      return props()?.canvasOrigin ?? window.location.origin
    },

    /**
     * Gets the context id that should be used when launching LTI iframes.
     */
    get containingCanvasLtiToolId(): string | null {
      const propsToolId = props()?.externalToolsConfig?.containingCanvasLtiToolId

      if (typeof propsToolId === 'string') {
        return propsToolId
      }

      try {
        if (cachedCanvasToolId === undefined) {
          // Fall back on localStorage until NQ implements
          cachedCanvasToolId = window.localStorage.getItem('canvas_tool_id')
        }

        return cachedCanvasToolId
      } catch {
        return null
      }
    },

    get editorSelection(): string | null {
      return editor?.selection?.getContent() ?? null
    },

    get editorContent(): string | null {
      return editor?.getContent() ?? null
    },

    insertCode(code: string) {
      if (this.rceWrapper?.insertCode) {
        this.rceWrapper.insertCode(code)
      }
    },

    replaceCode(code: string) {
      if (this.rceWrapper?.replaceCode) {
        this.rceWrapper.replaceCode(code)
      }
    },
  }
}
