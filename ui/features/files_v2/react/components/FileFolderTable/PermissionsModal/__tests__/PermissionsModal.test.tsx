/*
 * Copyright (C) 2025 - present Instructure, Inc.
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

import {render, screen, waitFor} from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import doFetchApi from '@canvas/do-fetch-api-effect'
import {FileManagementProvider} from '../../../../contexts/FileManagementContext'
import {createMockFileManagementContext} from '../../../../__tests__/createMockContext'
import {FAKE_FILES, FAKE_FOLDERS, FAKE_FOLDERS_AND_FILES} from '../../../../../fixtures/fakeData'
import {resetAndGetFilesEnv} from '../../../../../utils/filesEnvUtils'
import {createFilesContexts} from '../../../../../fixtures/fileContexts'
import PermissionsModal from '../PermissionsModal'

jest.mock('@canvas/do-fetch-api-effect')

const defaultProps = {
  open: true,
  items: FAKE_FOLDERS_AND_FILES,
  onDismiss: jest.fn(),
}

const renderComponent = (props?: any) =>
  render(
    <FileManagementProvider value={createMockFileManagementContext()}>
      <PermissionsModal {...defaultProps} {...props} />
    </FileManagementProvider>,
  )

describe('PermissionsModal', () => {
  beforeAll(() => {
    const filesContexts = createFilesContexts()
    resetAndGetFilesEnv(filesContexts)
  })

  beforeEach(() => {
    // Set up a default mock implementation for doFetchApi to prevent unhandled rejections
    ;(doFetchApi as jest.Mock).mockResolvedValue({})
  })

  afterEach(() => {
    jest.clearAllMocks()
    jest.resetAllMocks()
  })

  it('renders header', async () => {
    renderComponent()
    expect(await screen.getByText('Edit Permissions')).toBeInTheDocument()
  })

  describe('renders body', () => {
    describe('with preview', () => {
      it('for a files and folders', async () => {
        renderComponent()
        await waitFor(() => {
          expect(
            screen.getByText(`Selected Items (${FAKE_FOLDERS_AND_FILES.length})`),
          ).toBeInTheDocument()
        })
      })

      it('for a file', async () => {
        renderComponent({items: [FAKE_FILES[0]]})
        await waitFor(() => {
          expect(screen.getByText(FAKE_FILES[0].display_name)).toBeInTheDocument()
        })
      })

      it('for a folder', async () => {
        renderComponent({items: [FAKE_FOLDERS[0]]})
        await waitFor(() => {
          expect(screen.getByText(FAKE_FOLDERS[0].name)).toBeInTheDocument()
        })
      })
    })

    describe('with availability options', () => {
      it('for a single file', async () => {
        renderComponent({
          items: [FAKE_FILES[0]],
        })
        const input = await screen.findByTestId('permissions-availability-selector')
        expect(input).toBeInTheDocument()
        expect(input).toHaveAttribute('value', 'Publish')
      })

      it('for multiple files and folders', async () => {
        renderComponent()
        const input = await screen.findByTestId('permissions-availability-selector')
        expect(input).toBeInTheDocument()
        expect(input).toHaveAttribute('value', 'Publish')
      })
    })

    describe('with date ranges', () => {
      it('for a single file', async () => {
        renderComponent({
          items: [
            {
              ...FAKE_FILES[0],
              hidden: false,
              locked: false,
              unlock_at: '2025-04-12T00:00:00Z',
              lock_at: '2025-04-15T00:00:00Z',
            },
          ],
        })
        await waitFor(() => {
          expect(screen.getByText(/available from/i)).toBeInTheDocument()
          expect(screen.getByText(/until/i)).toBeInTheDocument()
        })
      })

      it('for multiple files and folders', async () => {
        renderComponent({
          items: FAKE_FOLDERS_AND_FILES.map(item => ({
            ...item,
            hidden: false,
            locked: false,
            unlock_at: '2025-04-12T00:00:00Z',
            lock_at: '2025-04-15T00:00:00Z',
          })),
        })
        await waitFor(() => {
          expect(screen.getByText(/available from/i)).toBeInTheDocument()
          expect(screen.getByText(/until/i)).toBeInTheDocument()
        })
      })

      // TODO: unskip failing tests (cf. RCX-3333)
      describe.skip('with date errors', () => {
        it('shows an error there are invalid dates', async () => {
          renderComponent({
            items: [
              {
                ...FAKE_FILES[0],
                unlock_at: '2025-04-12T00:00:00Z',
                lock_at: '2025-04-15T00:00:00Z',
              },
            ],
          })
          let input = await screen.getByLabelText(/available from/i)
          await userEvent.click(input)
          await userEvent.clear(input)
          await userEvent.type(input, 'banana')
          input = await screen.getByLabelText(/until/i)
          await userEvent.click(input)
          await userEvent.clear(input)
          await userEvent.type(input, 'avocado')
          await userEvent.click(screen.getByTestId('permissions-save-button'))
          const messages = await screen.getAllByText('Invalid date')
          expect(messages[0]).toBeInTheDocument()
          expect(messages[1]).toBeInTheDocument()
        })

        it('shows error when unlock date is after lock date', async () => {
          renderComponent({
            items: [
              {
                ...FAKE_FILES[0],
                unlock_at: '2026-04-12T00:00:00Z',
                lock_at: '2025-04-15T00:00:00Z',
              },
            ],
          })
          const availableInput = screen.getByLabelText(/available from/i)
          await userEvent.click(screen.getByTestId('permissions-save-button'))
          expect(
            await screen.findByText('Unlock date cannot be after lock date.'),
          ).toBeInTheDocument()
          expect(availableInput).toHaveFocus()
        })

        it('shows error when both lock_at and unlock_at are blank', async () => {
          renderComponent({
            items: [
              {
                ...FAKE_FILES[0],
                hidden: false,
                locked: false,
                unlock_at: '2025-04-12T00:00:00Z',
                lock_at: '2025-04-15T00:00:00Z',
              },
            ],
          })
          const availableInput = screen.getByLabelText(/available from/i)
          await userEvent.click(availableInput)
          await userEvent.clear(availableInput)
          const untilInput = screen.getByLabelText(/until/i)
          await userEvent.click(untilInput)
          await userEvent.clear(untilInput)
          await userEvent.click(untilInput)

          await userEvent.click(screen.getByTestId('permissions-save-button'))

          expect(await screen.findByText('Please enter at least one date.')).toBeInTheDocument()
          expect(availableInput).toHaveFocus()
        })
      })
    })

    describe('with visibility options', () => {
      it('for a single file', async () => {
        renderComponent({
          items: [FAKE_FILES[0]],
        })

        const input = await screen.findByTestId('permissions-visibility-selector')
        expect(input).toBeInTheDocument()
        expect(input).toHaveAttribute('value', 'Inherit from Course')
      })

      it('for multiple files and folders', async () => {
        renderComponent()

        const input = await screen.findByTestId('permissions-visibility-selector')
        expect(input).toBeInTheDocument()
        expect(input).toHaveAttribute('value', 'Inherit from Course')
      })

      it('for multiple files with keep option', async () => {
        renderComponent({
          items: [
            {...FAKE_FILES[0], visibility_level: 'inherit'},
            {...FAKE_FILES[1], visibility_level: 'context'},
          ],
        })

        const input = await screen.findByTestId('permissions-visibility-selector')
        expect(input).toBeInTheDocument()
        expect(input).toHaveAttribute('value', 'Keep')
      })
    })

    describe('without visibility options', () => {
      it('when is not a course context', async () => {
        render(
          <FileManagementProvider value={createMockFileManagementContext({contextType: 'user'})}>
            <PermissionsModal {...defaultProps} />
          </FileManagementProvider>,
        )
        await waitFor(() => {
          expect(screen.queryByTestId('permissions-visibility-selector')).not.toBeInTheDocument()
        })
      })

      it('when items only contain folders', async () => {
        renderComponent({
          items: FAKE_FOLDERS,
        })
        await waitFor(() => {
          expect(screen.queryByTestId('permissions-visibility-selector')).not.toBeInTheDocument()
        })
      })
    })
  })

  it('renders footer', async () => {
    renderComponent()
    await waitFor(() => {
      expect(screen.getByTestId('permissions-cancel-button')).toBeInTheDocument()
      expect(screen.getByTestId('permissions-save-button')).toBeInTheDocument()
    })
  })

  it.skip('shows an error there are invalid dates', async () => {
    renderComponent({
      items: [
        {
          ...FAKE_FILES[0],
          unlock_at: '2025-04-12T00:00:00Z',
          lock_at: '2025-04-15T00:00:00Z',
        },
      ],
    })
    let input = await screen.getByLabelText(/available from/i)
    await userEvent.click(input)
    await userEvent.clear(input)
    await userEvent.type(input, 'banana')
    input = await screen.getByLabelText(/until/i)
    await userEvent.click(input)
    await userEvent.clear(input)
    await userEvent.type(input, 'avocado')
    await userEvent.click(screen.getByTestId('permissions-save-button'))
    const messages = await screen.getAllByText('Invalid date')
    expect(messages[0]).toBeInTheDocument()
    expect(messages[1]).toBeInTheDocument()
  })

  it('performs fetch request and shows alert', async () => {
    renderComponent({
      items: [Object.assign({}, FAKE_FILES[0], {usage_rights: {}})],
    })

    // PUT request response
    ;(doFetchApi as jest.Mock).mockResolvedValueOnce({})
    await userEvent.click(screen.getByTestId('permissions-save-button'))

    await waitFor(() => {
      expect(screen.getAllByText(/permissions have been successfully set./i)[0]).toBeInTheDocument()
      expect(doFetchApi).toHaveBeenCalledWith({
        body: {
          hidden: false,
          lock_at: '',
          locked: false,
          unlock_at: '',
          visibility_level: 'inherit',
        },
        method: 'PUT',
        path: '/api/v1/files/178',
      })
    })
  })

  it('fails fetch request and shows alert', async () => {
    renderComponent({
      items: [Object.assign({}, FAKE_FILES[0], {usage_rights: {}})],
    })

    // PUT request response
    ;(doFetchApi as jest.Mock).mockRejectedValue({})
    await userEvent.click(await screen.getByTestId('permissions-save-button'))

    await waitFor(() => {
      expect(
        screen.getAllByText(/an error occurred while setting permissions. please try again./i)[0],
      ).toBeInTheDocument()
      expect(doFetchApi).toHaveBeenCalledWith({
        body: {
          hidden: false,
          lock_at: '',
          locked: false,
          unlock_at: '',
          visibility_level: 'inherit',
        },
        method: 'PUT',
        path: '/api/v1/files/178',
      })
    })
  })

  it('with alert after trying to save', async () => {
    const usageFilesContexts = createFilesContexts({
      usageRightsRequired: true,
    })
    resetAndGetFilesEnv(usageFilesContexts)

    renderComponent()
    await userEvent.click(screen.getByTestId('permissions-save-button'))
    expect(
      await screen.findByText(
        'Selected items must have usage rights assigned before they can be published.',
      ),
    ).toBeInTheDocument()
  })
})
