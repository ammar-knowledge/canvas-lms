/*
 * Copyright (C) 2022 - present Instructure, Inc.
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

import React from 'react'

import {Button} from '@instructure/ui-buttons'
import {Text} from '@instructure/ui-text'
import {View} from '@instructure/ui-view'

import Modal from '@canvas/instui-bindings/react/InstuiModal'
import {useScope as createI18nScope} from '@canvas/i18n'

const I18n = createI18nScope('reset_pace_warning_modal')

const {Body: ModalBody, Footer: ModalFooter} = Modal as any

export type ComponentProps = {
  open: boolean
  onCancel: () => void
  onConfirm: () => void
}

export const ResetPaceWarningModal = ({open, onCancel, onConfirm}: ComponentProps) => (
  <Modal
    data-testid="reset-changes-modal"
    size="small"
    open={open}
    onDismiss={onCancel}
    label={I18n.t('Reset all unpublished changes?')}
  >
    <ModalBody>
      <View>
        <Text>
          {I18n.t('Your unpublished changes will be reverted to their previously saved state.')}
        </Text>
      </View>
    </ModalBody>
    <ModalFooter>
      <View>
        <Button data-testid="reset-all-cancel-button" onClick={onCancel}>
          {I18n.t('Cancel')}
        </Button>
        <Button
          data-testid="reset-all-reset-button"
          margin="0 x-small"
          onClick={onConfirm}
          color="danger"
        >
          {I18n.t('Reset')}
        </Button>
      </View>
    </ModalFooter>
  </Modal>
)
