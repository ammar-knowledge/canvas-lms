/*
 * Copyright (C) 2021 - present Instructure, Inc.
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
import {render, waitFor} from '@testing-library/react'
import LearningMastery from '../index'
import useRollups from '../hooks/useRollups'
import fakeENV from '@canvas/test-utils/fakeENV'
import {Rating, Student, Outcome, StudentRollupData} from '../types/rollup'
import {SortOrder, SortBy} from '../utils/constants'

jest.mock('../hooks/useRollups')

describe('LearningMastery', () => {
  const ratings: Rating[] = [
    {
      color: 'blue',
      description: 'great!',
      mastery: false,
      points: 5,
    },
    {
      color: 'green',
      description: 'mastery!',
      mastery: true,
      points: 3,
    },
    {
      color: 'red',
      description: 'not great',
      mastery: false,
      points: 0,
    },
  ]

  const users: Student[] = [
    {
      id: '1',
      name: 'Student 1',
      display_name: 'Student 1',
      avatar_url: 'url',
    },
  ]

  const outcomes: Outcome[] = [
    {
      id: '1',
      title: 'outcome 1',
      description: 'Outcome description',
      display_name: 'Friendly outcome name',
      calculation_method: 'decaying_average',
      calculation_int: 65,
      mastery_points: 5,
      ratings,
    },
  ]

  const rollups: StudentRollupData[] = [
    {
      studentId: '1',
      outcomeRollups: [
        {
          outcomeId: '1',
          rating: {
            points: 3,
            color: 'green',
            description: 'rating description!',
            mastery: false,
          },
        },
      ],
    },
  ]

  interface DefaultProps {
    courseId?: string
  }

  const defaultProps = (props: DefaultProps = {}): {courseId: string} => {
    return {
      courseId: '1',
      ...props,
    }
  }

  beforeEach(() => {
    jest.useFakeTimers()
    fakeENV.setup({
      GRADEBOOK_OPTIONS: {
        outcome_proficiency: {ratings},
        ACCOUNT_LEVEL_MASTERY_SCALES: true,
        context_url: '/courses/1',
      },
      FEATURES: {instui_nav: true},
    })

    const mockUseRollups = useRollups as jest.MockedFunction<typeof useRollups>
    mockUseRollups.mockReturnValue({
      isLoading: false,
      students: users,
      gradebookFilters: [],
      setGradebookFilters: () => {},
      outcomes,
      rollups,
      setCurrentPage: jest.fn(),
      setStudentsPerPage: jest.fn(),
      sorting: {
        sortOrder: SortOrder.ASC,
        setSortOrder: jest.fn(),
        sortBy: SortBy.SortableName,
        setSortBy: jest.fn(),
      },
    })
  })

  afterEach(() => {
    const mockUseRollups = useRollups as jest.MockedFunction<typeof useRollups>
    mockUseRollups.mockClear()
    jest.clearAllMocks()
    jest.clearAllTimers()
    jest.useRealTimers()
    fakeENV.teardown()
  })

  it('renders a loading spinner when useRollups.isLoading is true', async () => {
    const mockUseRollups = useRollups as jest.MockedFunction<typeof useRollups>
    mockUseRollups.mockReturnValue({isLoading: true} as ReturnType<typeof useRollups>)
    const {getByText} = render(<LearningMastery {...defaultProps()} />)
    expect(getByText('Loading')).toBeInTheDocument()
  })

  it('renders the gradebook menu on the page', async () => {
    const {getByTestId} = render(<LearningMastery {...defaultProps()} />)
    expect(getByTestId('lmgb-gradebook-menu')).toBeInTheDocument()
  })

  it('renders each student, outcome, rollup from the response', async () => {
    const {getByText} = render(<LearningMastery {...defaultProps()} />)

    await waitFor(() => {
      expect(getByText('Student 1')).toBeInTheDocument()
    })

    expect(getByText('outcome 1')).toBeInTheDocument()
    expect(getByText('rating description!')).toBeInTheDocument()
  })

  it('calls useRollups with the provided courseId', () => {
    const mockUseRollups = useRollups as jest.MockedFunction<typeof useRollups>
    const props = defaultProps()
    render(<LearningMastery {...props} />)
    expect(mockUseRollups).toHaveBeenCalledWith({
      courseId: props.courseId,
      accountMasteryScalesEnabled: true,
    })
  })
})
